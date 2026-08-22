// Pure parsing and shaping of cdctl output for the Control D panel.
// Qt-free so it runs under node (test/model.test.js); Service.qml owns the
// processes and Panel.qml owns the rendering.

// cdctl exit codes that the panel maps to a distinct UI state. Everything else
// is a plain error line.
var EXIT_OK = 0
var EXIT_USAGE = 2
var EXIT_NOT_FOUND = 3
var EXIT_AUTH = 4
var EXIT_RETRYABLE = 8

function str(value) {
  return value === undefined || value === null ? "" : String(value)
}

function num(value, fallback) {
  var n = Number(value)
  return isFinite(n) ? n : (fallback === undefined ? 0 : fallback)
}

function strList(value) {
  if (!(value instanceof Array)) return []
  var out = []
  for (var i = 0; i < value.length; i++) {
    var item = str(value[i])
    if (item !== "") out.push(item)
  }
  return out
}

function parseJson(raw) {
  var text = str(raw).trim()
  if (text === "") return { ok: false, value: null, error: "empty output" }
  try {
    return { ok: true, value: JSON.parse(text), error: "" }
  } catch (e) {
    return { ok: false, value: null, error: "invalid JSON: " + String(e && e.message ? e.message : e) }
  }
}

// cdctl --json puts a `{"error": {code, message, hint, ...}}` envelope on
// stderr. Anything else on stderr (crash text, a shell "not found") is used
// verbatim.
function parseError(stderr, exitCode) {
  var parsed = parseJson(stderr)
  if (parsed.ok && parsed.value && parsed.value.error) {
    var err = parsed.value.error
    return {
      code: str(err.code),
      message: str(err.message),
      hint: str(err.hint),
      retryable: err.retryable === true,
      exitCode: num(exitCode, 1)
    }
  }
  var text = str(stderr).replace(/\s+/g, " ").trim()
  return {
    code: "",
    message: text,
    hint: "",
    retryable: num(exitCode, 1) === EXIT_RETRYABLE,
    exitCode: num(exitCode, 1)
  }
}

// One short line for the panel's status row.
function errorLine(err, fallback) {
  if (!err) return str(fallback)
  var text = str(err.message)
  if (text === "") text = str(fallback)
  return elide(text, 140)
}

function elide(text, max) {
  var value = str(text).replace(/\s+/g, " ").trim()
  var limit = max || 140
  return value.length > limit ? value.substring(0, limit - 1) + "…" : value
}

function parseAuthStatus(raw) {
  var parsed = parseJson(raw)
  if (!parsed.ok || !parsed.value || typeof parsed.value !== "object") {
    return { ok: false, authenticated: false, email: "", region: "", tokenSource: "", error: parsed.error }
  }
  var v = parsed.value
  return {
    ok: true,
    authenticated: v.authenticated === true,
    email: str(v.email),
    region: str(v.region),
    tokenSource: str(v.token_source),
    error: ""
  }
}

function normalizeProfile(p) {
  var da = p && p.default_action && typeof p.default_action === "object" ? p.default_action : {}
  return {
    id: str(p.id),
    name: str(p.name) || str(p.id),
    folders: num(p.folders),
    enabled: p.enabled !== false,
    disabledUntil: p.disabled_until === undefined ? null : p.disabled_until,
    defaultAction: str(da.action) || "bypass",
    updated: str(p.updated)
  }
}

function parseProfiles(raw) {
  var parsed = parseJson(raw)
  if (!parsed.ok) return { ok: false, profiles: [], error: parsed.error }
  if (!(parsed.value instanceof Array)) return { ok: false, profiles: [], error: "profile list is not an array" }
  var out = []
  for (var i = 0; i < parsed.value.length; i++) {
    var p = parsed.value[i]
    if (!p || typeof p !== "object" || str(p.id) === "") continue
    out.push(normalizeProfile(p))
  }
  return { ok: true, profiles: out, error: "" }
}

function normalizeRule(r) {
  var folderId = r.folder_id === undefined || r.folder_id === null || r.folder_id === 0 ? null : r.folder_id
  return {
    hostname: str(r.hostname),
    action: str(r.action),
    via: str(r.via),
    via6: str(r.via6),
    enabled: r.enabled !== false,
    folder: str(r.folder),
    folderId: folderId,
    order: num(r.order)
  }
}

function parseRules(raw) {
  var parsed = parseJson(raw)
  if (!parsed.ok) return { ok: false, rules: [], error: parsed.error }
  if (!(parsed.value instanceof Array)) return { ok: false, rules: [], error: "rule list is not an array" }
  var out = []
  for (var i = 0; i < parsed.value.length; i++) {
    var r = parsed.value[i]
    if (!r || typeof r !== "object" || str(r.hostname) === "") continue
    out.push(normalizeRule(r))
  }
  out.sort(function(a, b) { return a.order - b.order })
  return { ok: true, rules: out, error: "" }
}

function normalizeFolder(f) {
  return {
    id: f.id,
    name: str(f.name) || ("Folder " + str(f.id)),
    action: str(f.action),
    via: str(f.via),
    enabled: f.enabled !== false,
    rules: num(f.rules)
  }
}

function parseFolders(raw) {
  var parsed = parseJson(raw)
  if (!parsed.ok) return { ok: false, folders: [], error: parsed.error }
  if (!(parsed.value instanceof Array)) return { ok: false, folders: [], error: "folder list is not an array" }
  var out = []
  for (var i = 0; i < parsed.value.length; i++) {
    var f = parsed.value[i]
    if (!f || typeof f !== "object" || f.id === undefined || f.id === null) continue
    out.push(normalizeFolder(f))
  }
  return { ok: true, folders: out, error: "" }
}

// Which profile the panel shows: the persisted id if it still exists, else
// the first one. `preferred` may also be a name, since that is what a user
// would type into the settings form.
function resolveProfile(profiles, preferred) {
  var list = profiles || []
  if (list.length === 0) return null
  var want = str(preferred).trim()
  if (want !== "") {
    for (var i = 0; i < list.length; i++) if (list[i].id === want) return list[i]
    var lower = want.toLowerCase()
    for (var j = 0; j < list.length; j++) if (list[j].name.toLowerCase() === lower) return list[j]
  }
  return list[0]
}

// Rules as the panel lists them: root rules first, then one group per folder
// (in cdctl's folder order), each sorted by `order`. Folders with no rules
// still get a group so an empty folder is visible; rules whose folder id is
// unknown are grouped under the name cdctl resolved for them.
function groupRules(rules, folders) {
  var groups = []
  var byKey = {}
  function group(key, id, name, folder) {
    if (byKey[key]) return byKey[key]
    var g = { key: key, id: id, name: name, folder: folder || null, rules: [] }
    byKey[key] = g
    groups.push(g)
    return g
  }
  group("root", null, "", null)
  var list = folders || []
  for (var i = 0; i < list.length; i++) group("f:" + str(list[i].id), list[i].id, list[i].name, list[i])
  var items = rules || []
  for (var j = 0; j < items.length; j++) {
    var r = items[j]
    if (r.folderId === null) group("root").rules.push(r)
    else group("f:" + str(r.folderId), r.folderId, r.folder || ("Folder " + str(r.folderId)), null).rules.push(r)
  }
  return groups
}

// A flat, cursor-addressable list of the rows the RULES section renders, so
// keyboard navigation can walk headers and rules with one index.
function flattenGroups(groups) {
  var rows = []
  var list = groups || []
  for (var i = 0; i < list.length; i++) {
    var g = list[i]
    if (g.id !== null) rows.push({ kind: "folder", group: g })
    for (var j = 0; j < g.rules.length; j++) rows.push({ kind: "rule", rule: g.rules[j], group: g })
  }
  return rows
}

function countRules(rules) {
  var list = rules || []
  return { total: list.length, enabled: list.filter(function(r) { return r.enabled }).length }
}

// The rules the panel draws. Every other list in the panel is a top-N, and a
// profile with a few hundred rules would otherwise be the one section that
// scrolls without end. The cap counts rules, not rows, so folder headers do
// not eat into it; a header whose rules all fell outside the cut goes with
// them, since a heading for nothing is worse than the rules being missing.
function limitRuleRows(rows, maxRules) {
  var list = rows || []
  var limit = num(maxRules, 0)
  if (limit <= 0) return list.slice()
  var out = []
  var kept = 0
  var truncated = false
  for (var i = 0; i < list.length; i++) {
    if (list[i].kind !== "rule") { out.push(list[i]); continue }
    if (kept >= limit) { truncated = true; break }
    kept++
    out.push(list[i])
  }
  // Only when the list was cut: an empty folder that fits is shown on purpose.
  if (truncated) while (out.length > 0 && out[out.length - 1].kind === "folder") out.pop()
  return out
}

// What the RULES section says about itself. The hidden count only appears when
// something is hidden, so the common case reads as it always did.
function rulesCaption(count, shown) {
  if (!count || count.total === 0) return "No custom rules in this profile."
  if (num(shown, 0) < count.total)
    return "showing " + num(shown, 0) + " of " + count.total + " · " + count.enabled + " enabled"
  return count.enabled + " of " + count.total + " enabled"
}

// This machine's Control D endpoint is identified by the resolver it is
// actually using: every device's DoT hostname and DoH path carry its own
// device id, so `<uid>.dns.controld.com` or `dns.controld.com/<uid>` in the
// local DNS config names the endpoint exactly. Legacy shared resolvers
// (p1/p2/family.freedns.controld.com) carry no id and match nothing.
// The resolvers this panel knows how to read, most specific first. Order is
// the attribution rule: when two configs name the endpoint, the one doing the
// talking wins, and everything downstream of it is only repeating what it was
// told. `resolvconf` is last because the stub file names no manager at all.
var RESOLVERS = [
  { key: "ctrld", label: "ctrld" },
  { key: "stubby", label: "stubby" },
  { key: "dnscrypt", label: "dnscrypt-proxy" },
  { key: "unbound", label: "unbound" },
  { key: "dnsmasq", label: "dnsmasq" },
  { key: "nm", label: "NetworkManager" },
  { key: "resolved", label: "systemd-resolved" },
  { key: "resolvconf", label: "unknown" }
]

// Anything Control D answers from, whether or not it names a device: the
// shared legacy resolvers, the anycast addresses, and the prefix every
// device-specific v6 resolver sits in.
var CONTROLD_MARKER = /(dns\.controld\.com|\b2606:1a40:|\b76\.76\.(?:2|10)\.(?:2|11|22)\b)/i

// The probe arrives in labelled sections, because the same endpoint means
// different things depending on which config holds it. An undelimited blob is
// read as the stub file's, the one source that claims nothing about who wrote
// it.
// Whole lines only. A trailing `#` is not a comment in what this reads:
// systemd-resolved writes `76.76.2.22#hostname`, and the hostname is the
// identity, so cutting at the hash would throw the endpoint away.
function stripComments(text) {
  var lines = str(text).split("\n")
  var out = []
  for (var i = 0; i < lines.length; i++) if (!/^\s*[#;]/.test(lines[i])) out.push(lines[i])
  return out.join("\n")
}

function probeSections(text) {
  var out = { daemon: "" }
  for (var r = 0; r < RESOLVERS.length; r++) out[RESOLVERS[r].key] = ""
  var raw = stripComments(text)
  var parts = raw.split(/^@@([a-z]+)$/m)
  if (parts.length < 3) { out.resolvconf = raw; return out }
  for (var i = 1; i + 1 < parts.length; i += 2) {
    if (out.hasOwnProperty(parts[i])) out[parts[i]] = parts[i + 1]
  }
  return out
}

function hasText(haystack, needle) {
  var want = str(needle)
  return want !== "" && str(haystack).toLowerCase().indexOf(want.toLowerCase()) !== -1
}

// Every form a device publishes itself in, richest first so the transport a
// match reports is the one actually in use.
function deviceIdentities(device) {
  var out = []
  if (device.dot !== "") out.push({ value: device.dot, transport: "DNS-over-TLS" })
  if (device.doh !== "") out.push({ value: device.doh, transport: "DNS-over-HTTPS" })
  for (var i = 0; i < device.v6.length; i++) out.push({ value: device.v6[i], transport: "IPv6" })
  for (var j = 0; j < device.v4.length; j++) out.push({ value: device.v4[j], transport: "IPv4" })
  return out
}

// Which of this account's devices this machine resolves through, and which
// local config says so. Matching against the device list rather than against a
// hostname pattern is what lets the plain IPv6 and legacy IPv4 resolvers name
// the endpoint too: those carry the device id in an address, not in a name.
function matchEndpoint(devices, text) {
  var probe = probeSections(text)
  var list = devices || []
  for (var r = 0; r < RESOLVERS.length; r++) {
    var section = probe[RESOLVERS[r].key]
    if (str(section) === "") continue
    for (var d = 0; d < list.length; d++) {
      var forms = deviceIdentities(list[d])
      for (var f = 0; f < forms.length; f++) {
        if (hasText(section, forms[f].value))
          return { device: list[d], source: RESOLVERS[r].key, transport: forms[f].transport }
      }
    }
  }
  return { device: null, source: "", transport: "" }
}

// Control D is answering here even though no device matched: a legacy shared
// resolver, an endpoint owned by another account, or a device list we could
// not read. Distinct from Control D not being in the picture at all.
function controldPresent(text) {
  return CONTROLD_MARKER.test(stripComments(text))
}

// Whether Control D is what this machine resolves through now, rather than
// something a config file mentions. What the pause switch is really asking.
function controldLive(text) {
  var probe = probeSections(text)
  return CONTROLD_MARKER.test(probe.resolved) || CONTROLD_MARKER.test(probe.resolvconf)
}

// Whether a ctrld daemon is actually running here. The account keeps a `ctrld`
// block on a device long after the daemon is gone, so this question is only
// answerable on the machine.
function ctrldActive(text) {
  return /^active$/m.test(str(probeSections(text).daemon).trim())
}

// What on this machine talks to Control D. "Daemon" would presuppose one:
// systemd-resolved can hold the endpoint itself, with nothing in between.
function resolverLabel(source, daemonActive, ctrldVersion) {
  if (source === "ctrld" || daemonActive) {
    var version = str(ctrldVersion)
    return version !== "" ? "ctrld " + version : "ctrld"
  }
  for (var i = 0; i < RESOLVERS.length; i++)
    if (RESOLVERS[i].key === source) return RESOLVERS[i].label
  return "--"
}

// The endpoint is named but nothing says what manages it, which is the case
// worth hearing about: the panel offers to have the setup reported.
function resolverUnknown(source) {
  return source === "resolvconf"
}

function normalizeDevice(d) {
  var profile = d && d.profile && typeof d.profile === "object" ? d.profile : {}
  var resolvers = d && d.resolvers && typeof d.resolvers === "object" ? d.resolvers : {}
  var ctrld = d && d.ctrld && typeof d.ctrld === "object" ? d.ctrld : null
  return {
    id: str(d.id),
    name: str(d.name),
    profileId: str(profile.id),
    profileName: str(profile.name),
    // "active" is protected; the two disabled states are a stood-down device.
    // "pending" means it has never made a query, which is not a pause.
    status: str(d.status),
    ctrldVersion: ctrld ? str(ctrld.version) : "",
    // "none" is analytics reported as off. An absent level is unreported,
    // which is not the same answer, so it keeps its own empty value.
    analytics: d.analytics === undefined || d.analytics === null ? "" : str(d.analytics),
    dot: str(resolvers.dot),
    doh: str(resolvers.doh),
    // Device-specific addresses, which name the endpoint with no proxy in the
    // way. Always arrays per cdctl's contract, empty when the API omits them.
    v4: strList(resolvers.v4),
    v6: strList(resolvers.v6)
  }
}

function parseDevices(raw) {
  var parsed = parseJson(raw)
  if (!parsed.ok) return { ok: false, devices: [], error: parsed.error }
  if (!(parsed.value instanceof Array)) return { ok: false, devices: [], error: "device list is not an array" }
  var out = []
  for (var i = 0; i < parsed.value.length; i++) {
    var d = parsed.value[i]
    if (!d || typeof d !== "object") continue
    var device = normalizeDevice(d)
    if (device.id !== "") out.push(device)
  }
  return { ok: true, devices: out, error: "" }
}

// One device, as `cdctl device update` prints it back after verifying the
// write. The same shape as a list entry, so it can replace one outright.
function parseDevice(raw) {
  var parsed = parseJson(raw)
  if (!parsed.ok) return { ok: false, device: null, error: parsed.error }
  if (!parsed.value || typeof parsed.value !== "object" || parsed.value instanceof Array)
    return { ok: false, device: null, error: "not a device" }
  var device = normalizeDevice(parsed.value)
  if (device.id === "") return { ok: false, device: null, error: "device has no id" }
  return { ok: true, device: device, error: "" }
}

// The device list with one entry replaced by a newer read of it.
function replaceDevice(devices, device) {
  var list = devices || []
  if (!device) return list
  var out = []
  for (var i = 0; i < list.length; i++) out.push(list[i].id === device.id ? device : list[i])
  return out
}

// Whether Control D is filtering for this device, as the account sees it.
// Only the two disabled states are a pause: "pending" is a device that has
// never made a query, which is not the same as one stood down.
function deviceProtected(device) {
  if (!device) return false
  return device.status !== "soft-disabled" && device.status !== "hard-disabled"
}

// Whether this endpoint's analytics can be read. "none" is the only answer
// that means no: an unreported level is unknown, and the fetch settles it.
function analyticsReadable(device) {
  return !!device && device.analytics !== "none"
}

// Which machine this panel can describe. Everything it shows hangs off an
// identified endpoint, so the reason there is none has to survive: a machine
// with no Control D resolver at all is a different story to one whose resolver
// we cannot put a name to, and only the first means "unprotected".
var ENDPOINT_PENDING = "pending"
var ENDPOINT_NONE = "none"
var ENDPOINT_UNKNOWN = "unknown"
var ENDPOINT_MACHINE = "machine"

function endpointState(resolverChecked, controldFound, devicesChecked, endpoint) {
  if (!resolverChecked) return ENDPOINT_PENDING
  // A matched device is proof and outranks the marker heuristic below it: a
  // legacy v4 resolver names a device without looking like Control D anywhere
  // in the config, and asking whether this looks like Control D first would
  // deny an endpoint the account positively identified.
  if (endpoint) return ENDPOINT_MACHINE
  if (!controldFound) return ENDPOINT_NONE
  // A resolver we cannot name. Either the device lookup has not answered yet,
  // or it answered and this endpoint is not in the account.
  return devicesChecked ? ENDPOINT_UNKNOWN : ENDPOINT_PENDING
}

// The profile the panel describes: the one this machine's endpoint enforces
// when that is known, else the browsed selection. Machine state wins, so the
// panel never describes a profile the machine is not using.
function activeProfile(profiles, endpointProfileId, selectedId) {
  var enforced = str(endpointProfileId)
  if (enforced !== "") {
    var list = profiles || []
    for (var i = 0; i < list.length; i++) if (list[i].id === enforced) return list[i]
  }
  return resolveProfile(profiles, selectedId)
}

// Hero meta when this machine's endpoint is known: what it enforces and how.
function endpointLine(device, transport) {
  if (!device) return ""
  var parts = []
  if (device.profileName !== "") parts.push(device.profileName)
  if (str(transport) !== "") parts.push(str(transport))
  return parts.length > 0 ? parts.join(" · ") : "Control D"
}

// scripts/stats.py fans the analytics calls into one document per (window,
// action) pair, so this only has to validate it.
function parseStats(raw) {
  var parsed = parseJson(raw)
  var empty = {
    ok: false, hours: 0, action: 0,
    totals: { all: 0, blocked: 0, bypassed: 0, redirected: 0 },
    series: [], domains: [], filters: [], networks: [], countries: [], error: ""
  }
  if (!parsed.ok || !parsed.value || typeof parsed.value !== "object") {
    empty.error = parsed.error || "bad stats output"
    return empty
  }
  var v = parsed.value
  if (v.ok !== true) {
    empty.error = str(v.error) || "analytics failed"
    return empty
  }
  var totals = v.totals && typeof v.totals === "object" ? v.totals : {}
  return {
    ok: true,
    hours: num(v.hours, 24),
    action: num(v.action),
    totals: {
      all: num(totals.all),
      blocked: num(totals.blocked),
      bypassed: num(totals.bypassed),
      redirected: num(totals.redirected)
    },
    series: parseSeries(v.series),
    domains: parseCounts(v.domains),
    filters: parseCounts(v.filters),
    networks: parseCounts(v.networks),
    countries: parseCounts(v.countries),
    error: ""
  }
}

function parseCounts(list) {
  var out = []
  var items = list instanceof Array ? list : []
  for (var i = 0; i < items.length; i++) {
    var entry = items[i]
    if (!entry || str(entry.value) === "") continue
    out.push({ value: str(entry.value), count: num(entry.count) })
  }
  return out
}

function parseSeries(list) {
  var out = []
  var items = list instanceof Array ? list : []
  for (var i = 0; i < items.length; i++) {
    var bucket = items[i]
    if (!bucket) continue
    out.push({ time: str(bucket.time), total: num(bucket.total), blocked: num(bucket.blocked) })
  }
  return out
}

// The action the lists describe. Values are the API's, and the labels are the
// dashboard's tabs.
var ACTION_BLOCKED = 0
var ACTION_BYPASSED = 1
var ACTION_REDIRECTED = 2
var ACTION_SPOOFED = 3

function actionOptions() {
  return [
    { value: String(ACTION_BLOCKED), label: "Blocked" },
    { value: String(ACTION_BYPASSED), label: "Bypassed" },
    { value: String(ACTION_REDIRECTED), label: "Redirected" }
  ]
}

// What the activity log is filtered to: one chip per verdict, and every row
// under exactly one of them. Blocked is the default, being the verdict you
// come to the log for when a site will not load. Bypassed earns its own chip
// now that its rows are actionable -- the glyph there blocks the host -- and
// "Others" is where a redirect or a spoof is visible at all: among a page of
// blocked and bypassed it would never be found. Empty most days, which is
// itself the answer.
function activityFilterOptions() {
  return [
    { value: "blocked", label: "Blocked" },
    { value: "bypassed", label: "Bypassed" },
    { value: "others", label: "Others" }
  ]
}

// How far back a chip looks. A redirect or a spoof may be the only one all
// day, so the rare chip reaches further: at six hours it would report that
// none happened when one did, which is a different claim.
function activityHours(filter) {
  return str(filter) === "others" ? 24 : 6
}

// The verdicts a chip asks for. The API takes `action[]` repeatedly, so even
// "Others" narrows server side: a page filtered to a verdict is a page of it,
// not the handful that survive a client-side sieve.
function activityActions(filter) {
  switch (str(filter)) {
  case "bypassed": return [ACTION_BYPASSED]
  case "others": return [ACTION_REDIRECTED, ACTION_SPOOFED]
  default: return [ACTION_BLOCKED]
  }
}

// The windows the dashboard offers, minus Real-Time and Custom.
function windowOptions() {
  return [
    { value: "1", label: "1h" },
    { value: "24", label: "24h" },
    { value: "168", label: "7d" },
    { value: "720", label: "30d" }
  ]
}

// Bars are drawn against the biggest row rather than the total, so the top row
// always fills: a list where every bar is 2% wide says nothing.
function meterRatio(count, rows) {
  var items = rows || []
  var max = 0
  for (var i = 0; i < items.length; i++) max = Math.max(max, num(items[i].count))
  if (max <= 0) return 0
  return Math.max(0, Math.min(1, num(count) / max))
}

// Query counts run to five and six digits, and the panel has one column for
// them: 21432 -> "21.4K".
function formatCount(value) {
  var n = num(value)
  if (n < 1000) return String(n)
  if (n < 1000000) {
    var thousands = n / 1000
    return (thousands < 10 ? thousands.toFixed(1) : Math.round(thousands)) + "K"
  }
  var millions = n / 1000000
  return (millions < 10 ? millions.toFixed(1) : Math.round(millions)) + "M"
}

function blockedShare(total, blocked) {
  var t = num(total)
  if (t <= 0) return ""
  return Math.round((num(blocked) / t) * 100) + "%"
}

// ISO 3166-1 alpha-2 to everyday country name, generated from the iso-codes
// package so the panel can spell out what analytics reports as two letters.
var COUNTRY_NAMES = {
  AD:"Andorra", AE:"United Arab Emirates", AF:"Afghanistan", AG:"Antigua and Barbuda",
  AI:"Anguilla", AL:"Albania", AM:"Armenia", AO:"Angola",
  AQ:"Antarctica", AR:"Argentina", AS:"American Samoa", AT:"Austria",
  AU:"Australia", AW:"Aruba", AX:"Åland Islands", AZ:"Azerbaijan",
  BA:"Bosnia and Herzegovina", BB:"Barbados", BD:"Bangladesh", BE:"Belgium",
  BF:"Burkina Faso", BG:"Bulgaria", BH:"Bahrain", BI:"Burundi",
  BJ:"Benin", BL:"Saint Barthélemy", BM:"Bermuda", BN:"Brunei Darussalam",
  BO:"Bolivia", BQ:"Bonaire", BR:"Brazil", BS:"Bahamas",
  BT:"Bhutan", BV:"Bouvet Island", BW:"Botswana", BY:"Belarus",
  BZ:"Belize", CA:"Canada", CC:"Cocos (Keeling) Islands", CD:"Congo",
  CF:"Central African Republic", CG:"Congo", CH:"Switzerland", CI:"Côte d'Ivoire",
  CK:"Cook Islands", CL:"Chile", CM:"Cameroon", CN:"China",
  CO:"Colombia", CR:"Costa Rica", CU:"Cuba", CV:"Cabo Verde",
  CW:"Curaçao", CX:"Christmas Island", CY:"Cyprus", CZ:"Czechia",
  DE:"Germany", DJ:"Djibouti", DK:"Denmark", DM:"Dominica",
  DO:"Dominican Republic", DZ:"Algeria", EC:"Ecuador", EE:"Estonia",
  EG:"Egypt", EH:"Western Sahara", ER:"Eritrea", ES:"Spain",
  ET:"Ethiopia", FI:"Finland", FJ:"Fiji", FK:"Falkland Islands (Malvinas)",
  FM:"Micronesia", FO:"Faroe Islands", FR:"France", GA:"Gabon",
  GB:"United Kingdom", GD:"Grenada", GE:"Georgia", GF:"French Guiana",
  GG:"Guernsey", GH:"Ghana", GI:"Gibraltar", GL:"Greenland",
  GM:"Gambia", GN:"Guinea", GP:"Guadeloupe", GQ:"Equatorial Guinea",
  GR:"Greece", GS:"South Georgia and the South Sandwich Islands", GT:"Guatemala", GU:"Guam",
  GW:"Guinea-Bissau", GY:"Guyana", HK:"Hong Kong", HM:"Heard Island and McDonald Islands",
  HN:"Honduras", HR:"Croatia", HT:"Haiti", HU:"Hungary",
  ID:"Indonesia", IE:"Ireland", IL:"Israel", IM:"Isle of Man",
  IN:"India", IO:"British Indian Ocean Territory", IQ:"Iraq", IR:"Iran",
  IS:"Iceland", IT:"Italy", JE:"Jersey", JM:"Jamaica",
  JO:"Jordan", JP:"Japan", KE:"Kenya", KG:"Kyrgyzstan",
  KH:"Cambodia", KI:"Kiribati", KM:"Comoros", KN:"Saint Kitts and Nevis",
  KP:"North Korea", KR:"South Korea", KW:"Kuwait", KY:"Cayman Islands",
  KZ:"Kazakhstan", LA:"Laos", LB:"Lebanon", LC:"Saint Lucia",
  LI:"Liechtenstein", LK:"Sri Lanka", LR:"Liberia", LS:"Lesotho",
  LT:"Lithuania", LU:"Luxembourg", LV:"Latvia", LY:"Libya",
  MA:"Morocco", MC:"Monaco", MD:"Moldova", ME:"Montenegro",
  MF:"Saint Martin (French part)", MG:"Madagascar", MH:"Marshall Islands", MK:"North Macedonia",
  ML:"Mali", MM:"Myanmar", MN:"Mongolia", MO:"Macao",
  MP:"Northern Mariana Islands", MQ:"Martinique", MR:"Mauritania", MS:"Montserrat",
  MT:"Malta", MU:"Mauritius", MV:"Maldives", MW:"Malawi",
  MX:"Mexico", MY:"Malaysia", MZ:"Mozambique", NA:"Namibia",
  NC:"New Caledonia", NE:"Niger", NF:"Norfolk Island", NG:"Nigeria",
  NI:"Nicaragua", NL:"Netherlands", NO:"Norway", NP:"Nepal",
  NR:"Nauru", NU:"Niue", NZ:"New Zealand", OM:"Oman",
  PA:"Panama", PE:"Peru", PF:"French Polynesia", PG:"Papua New Guinea",
  PH:"Philippines", PK:"Pakistan", PL:"Poland", PM:"Saint Pierre and Miquelon",
  PN:"Pitcairn", PR:"Puerto Rico", PS:"Palestine", PT:"Portugal",
  PW:"Palau", PY:"Paraguay", QA:"Qatar", RE:"Réunion",
  RO:"Romania", RS:"Serbia", RU:"Russian Federation", RW:"Rwanda",
  SA:"Saudi Arabia", SB:"Solomon Islands", SC:"Seychelles", SD:"Sudan",
  SE:"Sweden", SG:"Singapore", SH:"Saint Helena", SI:"Slovenia",
  SJ:"Svalbard and Jan Mayen", SK:"Slovakia", SL:"Sierra Leone", SM:"San Marino",
  SN:"Senegal", SO:"Somalia", SR:"Suriname", SS:"South Sudan",
  ST:"Sao Tome and Principe", SV:"El Salvador", SX:"Sint Maarten (Dutch part)", SY:"Syria",
  SZ:"Eswatini", TC:"Turks and Caicos Islands", TD:"Chad", TF:"French Southern Territories",
  TG:"Togo", TH:"Thailand", TJ:"Tajikistan", TK:"Tokelau",
  TL:"Timor-Leste", TM:"Turkmenistan", TN:"Tunisia", TO:"Tonga",
  TR:"Türkiye", TT:"Trinidad and Tobago", TV:"Tuvalu", TW:"Taiwan",
  TZ:"Tanzania", UA:"Ukraine", UG:"Uganda", UM:"United States Minor Outlying Islands",
  US:"United States", UY:"Uruguay", UZ:"Uzbekistan", VA:"Holy See (Vatican City State)",
  VC:"Saint Vincent and the Grenadines", VE:"Venezuela", VG:"Virgin Islands", VI:"Virgin Islands",
  VN:"Vietnam", VU:"Vanuatu", WF:"Wallis and Futuna", WS:"Samoa",
  YE:"Yemen", YT:"Mayotte", ZA:"South Africa", ZM:"Zambia",
  ZW:"Zimbabwe"
}

// Analytics reports countries as codes. Spell them where we know them, and
// keep the code when we do not rather than showing nothing.
function countryName(code) {
  var key = str(code).toUpperCase()
  if (key === "") return ""
  return COUNTRY_NAMES[key] || key
}

// Filter ids come back as slugs; the dashboard shows titles we do not have,
// so make the slug readable rather than inventing a name.
function filterLabel(value) {
  var name = str(value).replace(/^x-/, "").replace(/[-_]+/g, " ").trim()
  return name === "" ? "unknown" : name.charAt(0).toUpperCase() + name.slice(1)
}

// scripts/activity.py returns the endpoint's most recent lookups, newest
// first, with the A/AAAA pairs of one lookup already collapsed.
function parseActivity(raw) {
  var parsed = parseJson(raw)
  if (!parsed.ok || !parsed.value || typeof parsed.value !== "object") {
    return { ok: false, queries: [], error: parsed.error || "bad activity output" }
  }
  var v = parsed.value
  if (v.ok !== true) return { ok: false, queries: [], error: str(v.error) || "activity log failed" }
  var out = []
  var list = v.queries instanceof Array ? v.queries : []
  for (var i = 0; i < list.length; i++) {
    var q = list[i]
    if (!q || str(q.question) === "") continue
    out.push({
      time: str(q.time),
      question: str(q.question),
      action: num(q.action, -1),
      trigger: str(q.trigger),
      triggerValue: str(q.triggerValue),
      protocol: str(q.protocol),
      types: q.types instanceof Array ? q.types.map(str) : [],
      repeats: num(q.repeats, 1)
    })
  }
  return { ok: true, queries: out, error: "" }
}

// Analytics reports the verdict as an integer; the rest of the panel speaks
// the names cdctl uses.
function actionName(action) {
  switch (num(action, -1)) {
  case 0: return "block"
  case 1: return "bypass"
  case 2: return "redirect"
  case 3: return "spoof"
  default: return ""
  }
}

// Wall clock for a log row. Local time, since the reader is looking at what
// their own machine just did.
function clockTime(iso) {
  var text = str(iso)
  if (text === "") return ""
  var when = new Date(text)
  if (isNaN(when.getTime())) return ""
  function pad(n) { return n < 10 ? "0" + n : String(n) }
  return pad(when.getHours()) + ":" + pad(when.getMinutes()) + ":" + pad(when.getSeconds())
}

// Second line of a log row: what decided it, and what else it carried.
function activityDetail(query) {
  if (!query) return ""
  var parts = []
  var name = actionName(query.action)
  if (name !== "") parts.push(name)
  if (query.triggerValue !== "") parts.push(filterLabel(query.triggerValue))
  else if (query.trigger !== "") parts.push(query.trigger)
  if (query.types.length > 0) parts.push(query.types.join("/"))
  // How many times this host was asked for in the window. One row and a count
  // beats a screenful of the same name.
  if (query.repeats > 1) parts.push("x" + query.repeats)
  return parts.join(" · ")
}

// Rows the profile has since overruled. The log is a record of lookups, so
// allowing a host leaves every lookup it was blocked on standing -- and the
// blocked view would go on listing a host that is no longer blocked, with the
// glyph saying so. A row whose host now has a rule pointing the other way is
// history the view is not for.
function dropOverridden(queries, rules) {
  var list = queries || []
  var out = []
  for (var i = 0; i < list.length; i++) {
    var rule = findRule(rules, list[i].question)
    if (rule !== null && rule.enabled && rule.action !== actionName(list[i].action)) continue
    out.push(list[i])
  }
  return out
}

// A row acted on stays in the log even once the fetch stops returning it:
// bypassing a host means it stops being blocked, so the very act of using the
// blocked view removes what you just used it on, and with it the only way to
// take the override back. Merged by time so the row keeps its place rather
// than jumping to the top.
function mergeSticky(queries, sticky, actions) {
  var out = (queries || []).slice()
  var held = sticky || []
  var want = actions || []
  for (var i = 0; i < held.length; i++) {
    var q = held[i]
    // Only into the view whose verdict it is: a blocked row held for its undo
    // does not belong under Bypassed just because that is what is on screen.
    var fits = want.length === 0
    for (var w = 0; w < want.length; w++) if (want[w] === q.action) { fits = true; break }
    if (!fits) continue
    var seen = false
    for (var j = 0; j < out.length; j++)
      if (out[j].question === q.question && out[j].action === q.action) { seen = true; break }
    if (!seen) out.push(q)
  }
  out.sort(function(a, b) { return str(b.time).localeCompare(str(a.time)) })
  return out
}

// What the add form will hand to cdctl. The API does the real validation;
// this only keeps the obvious mistakes from becoming a failed request: a URL
// pasted whole, a stray space, an empty box. A leading "*." is legal and is
// the only place a wildcard may sit.
function validHostname(text) {
  var host = str(text).trim().toLowerCase()
  if (host === "" || host.length > 253) return false
  if (/[\s\/:]/.test(host)) return false
  var body = host.indexOf("*.") === 0 ? host.substring(2) : host
  if (body.indexOf("*") !== -1) return false
  if (!/^[a-z0-9.-]+$/.test(body)) return false
  if (body.indexOf("..") !== -1) return false
  if (body.charAt(0) === "." || body.charAt(0) === "-") return false
  if (body.charAt(body.length - 1) === "." || body.charAt(body.length - 1) === "-") return false
  return body.indexOf(".") > 0
}

// The override an activity row offers: the opposite of what happened to it.
// Only the two verdicts a custom rule can reverse. A redirect or a spoof is
// already somebody's deliberate rule, and unmatched means nothing decided.
function overrideAction(query) {
  if (!query) return ""
  if (query.action === 0) return "bypass"
  if (query.action === 1) return "block"
  return ""
}

// The rule this profile already holds for a hostname, if any. Exact matches
// only: a rule on the parent domain covers this host too, but it is not this
// host's rule and removing it would reach further than the row asked.
function findRule(rules, hostname) {
  var want = str(hostname).toLowerCase()
  if (want === "") return null
  var list = rules || []
  for (var i = 0; i < list.length; i++)
    if (list[i].hostname.toLowerCase() === want) return list[i]
  return null
}

// What pressing the row's action does, given what the profile already says.
// A host this profile has a rule for offers to have it taken away, whichever
// way the log now reads: once a bypass takes effect the row turns up bypassed,
// and inverting it there would quietly turn an allow into a deny. Everything
// else offers the opposite of the verdict recorded.
function ruleIntent(query, rules) {
  var action = overrideAction(query)
  if (action === "") return { action: "", verb: "", hostname: "" }
  var host = str(query.question)
  var rule = findRule(rules, host)
  if (rule === null) return { action: action, verb: "create", hostname: host }
  return { action: rule.action, verb: "delete", hostname: host }
}

// What a row offers when the profile already holds a rule for it. Naming the
// operation rather than drawing the verdict it would leave behind: removing a
// rule hands the host back to whatever else decides, and the panel does not
// know what that will say.
var UNDO_GLYPH = "\udb81\udd4c"

// A rule's own row offers to switch it off, or back on, and to delete it.
// Toggling does not change what the rule does, so there is no verdict to
// preview: the glyph names the operation, and says which way it runs -- pause
// on a rule that is running, play on one that is not.
var PAUSE_GLYPH = "\udb80\udfe4"
var PLAY_GLYPH = "\udb81\udc0a"
var PLUS_GLYPH = "\udb81\udc15"
var TRASH_GLYPH = "\udb82\ude7a"

// Nerd Font glyphs, matching what the built-in panels use for their rows.
function actionGlyph(action) {
  switch (str(action)) {
  case "block": return "󰂭"
  case "bypass": return "󰄬"
  case "spoof": return "󰑥"
  case "redirect": return "󰁔"
  default: return "󰇖"
  }
}

function actionLabel(action) {
  var a = str(action)
  return a === "" ? "unknown" : a
}

// Second line of a rule row: action, plus where it points for spoof/redirect.
function ruleDetail(rule) {
  if (!rule) return ""
  var parts = [actionLabel(rule.action)]
  if (rule.via !== "") parts.push(rule.via)
  if (rule.via6 !== "") parts.push(rule.via6)
  if (!rule.enabled) parts.push("disabled")
  return parts.join(" · ")
}

// Hero meta line.
function accountLine(auth) {
  if (!auth || !auth.authenticated) return "Not authenticated"
  var parts = []
  if (auth.email !== "") parts.push(auth.email)
  if (auth.region !== "") parts.push(auth.region)
  return parts.length > 0 ? parts.join(" · ") : "Authenticated"
}
