// Pure, Qt-free parsing and shaping of cdctl output, so it runs under node too
// (test/model.test.js). Service.qml owns the processes, Panel.qml the rendering.

// Exit 4 sends the reader to `cdctl auth login`; exit 8 is worth retrying.
var EXIT_AUTH = 4
var EXIT_RETRYABLE = 8

function str(value) {
  return value === undefined || value === null ? "" : String(value)
}

// A missing value is not a zero: `Number(null)` and `Number("")` are both a
// finite 0, so testing the conversion alone would swallow the fallback.
function num(value, fallback) {
  var fall = fallback === undefined ? 0 : fallback
  if (typeof value !== "number" && (typeof value !== "string" || value.trim() === "")) return fall
  var n = Number(value)
  return isFinite(n) ? n : fall
}

function strList(value) {
  if (!(value instanceof Array)) return []
  return value.map(str).filter(function(item) { return item !== "" })
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

// Every cdctl list is a JSON array of objects; `normalize` returns null to drop one.
function parseList(raw, label, normalize) {
  var parsed = parseJson(raw)
  if (!parsed.ok) return { ok: false, items: [], error: parsed.error }
  if (!(parsed.value instanceof Array)) return { ok: false, items: [], error: label + " list is not an array" }
  var out = []
  for (var i = 0; i < parsed.value.length; i++) {
    var entry = parsed.value[i]
    if (!entry || typeof entry !== "object") continue
    var item = normalize(entry)
    if (item !== null) out.push(item)
  }
  return { ok: true, items: out, error: "" }
}

// cdctl --json puts a `{"error": {...}}` envelope on stderr; anything else
// there (crash text, a shell "not found") is used verbatim. Exit 8 is
// retryable whether or not the envelope repeats it.
function parseError(stderr, exitCode) {
  var code = num(exitCode, 1)
  var parsed = parseJson(stderr)
  var err = parsed.ok && parsed.value ? parsed.value.error : null
  if (err) {
    return {
      code: str(err.code),
      message: str(err.message),
      hint: str(err.hint),
      retryable: err.retryable === true || code === EXIT_RETRYABLE,
      exitCode: code
    }
  }
  return {
    code: "",
    message: str(stderr).replace(/\s+/g, " ").trim(),
    hint: "",
    retryable: code === EXIT_RETRYABLE,
    exitCode: code
  }
}

// One short line for the panel's status row. cdctl marks the failures it
// expects to clear on their own, and the panel has no retry of its own to
// offer; the suffix saying so comes out of the budget, not on top of it.
function errorLine(err, fallback) {
  if (!err) return str(fallback)
  var text = str(err.message) || str(fallback)
  var suffix = err.retryable ? " (worth retrying)" : ""
  return elide(text, 140 - suffix.length) + suffix
}

// The marker counts towards the limit: `max` is what the caller has room for.
function elide(text, max) {
  var value = str(text).replace(/\s+/g, " ").trim()
  var limit = max || 140
  return value.length > limit ? value.substring(0, Math.max(0, limit - 3)) + "..." : value
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

function parseProfiles(raw) {
  var r = parseList(raw, "profile", function(p) {
    if (str(p.id) === "") return null
    var da = p.default_action && typeof p.default_action === "object" ? p.default_action : {}
    return {
      id: str(p.id),
      name: str(p.name) || str(p.id),
      folders: num(p.folders),
      enabled: p.enabled !== false,
      disabledUntil: p.disabled_until === undefined ? null : p.disabled_until,
      defaultAction: str(da.action) || "bypass",
      updated: str(p.updated)
    }
  })
  return { ok: r.ok, profiles: r.items, error: r.error }
}

function parseRules(raw) {
  var r = parseList(raw, "rule", function(rule) {
    // Without an action there is nothing to draw and nothing to undo, and
    // `ruleIntent` would read the gap as an offer to delete.
    if (str(rule.hostname) === "" || str(rule.action) === "") return null
    return {
      hostname: str(rule.hostname),
      action: str(rule.action),
      via: str(rule.via),
      via6: str(rule.via6),
      enabled: rule.enabled !== false,
      folder: str(rule.folder),
      folderId: rule.folder_id == null || rule.folder_id === 0 ? null : rule.folder_id,
      order: num(rule.order)
    }
  })
  r.items.sort(function(a, b) { return a.order - b.order })
  return { ok: r.ok, rules: r.items, error: r.error }
}

function parseFolders(raw) {
  var r = parseList(raw, "folder", function(f) {
    if (f.id === undefined || f.id === null) return null
    return {
      id: f.id,
      name: str(f.name) || ("Folder " + str(f.id)),
      action: str(f.action),
      via: str(f.via),
      enabled: f.enabled !== false,
      rules: num(f.rules)
    }
  })
  return { ok: r.ok, folders: r.items, error: r.error }
}

// The persisted id if it still exists, else the first profile. A name is
// accepted as well as an id, so a profile can be asked for by what it is called.
function resolveProfile(profiles, preferred) {
  var list = profiles || []
  var want = str(preferred).trim()
  if (want !== "") {
    for (var i = 0; i < list.length; i++) if (list[i].id === want) return list[i]
    var lower = want.toLowerCase()
    for (var j = 0; j < list.length; j++) if (list[j].name.toLowerCase() === lower) return list[j]
  }
  return list.length > 0 ? list[0] : null
}

// Root rules first, then one group per folder in cdctl's order. An empty
// folder still gets a group so it stays visible; a rule whose folder id is not
// in the list is grouped under the name cdctl resolved for it.
function groupRules(rules, folders) {
  var groups = []
  var byKey = {}
  function group(key, id, name, folder) {
    if (!byKey[key]) {
      byKey[key] = { key: key, id: id, name: name, folder: folder || null, rules: [] }
      groups.push(byKey[key])
    }
    return byKey[key]
  }
  group("root", null, "", null)
  var list = folders || []
  for (var i = 0; i < list.length; i++) group("f:" + str(list[i].id), list[i].id, list[i].name, list[i])
  var items = rules || []
  for (var j = 0; j < items.length; j++) {
    var r = items[j]
    if (r.folderId === null) byKey["root"].rules.push(r)
    else group("f:" + str(r.folderId), r.folderId, r.folder || ("Folder " + str(r.folderId)), null).rules.push(r)
  }
  return groups
}

// Headers and rules in one list, so the cursor walks them with a single index.
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

// Uncapped, a profile with a few hundred rules is the one section that scrolls
// without end. The cap counts rules, not rows, so folder headers do not eat
// into it; a header whose rules all fell outside the cut goes with them.
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


// The resolvers this panel can read. Order is the attribution rule: when two
// configs name the endpoint, the one doing the talking wins and everything
// downstream only repeats it. `resolvconf` last, since a stub names no manager.
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

// Anything Control D answers from, named device or not: the legacy shared
// resolvers, the anycast addresses, the device-specific v6 prefix.
var CONTROLD_MARKER = /(dns\.controld\.com|\b2606:1a40:|\b76\.76\.(?:2|10)\.(?:2|11|22)\b)/i

// Whole lines only. A trailing `#` is not a comment here: systemd-resolved
// writes `76.76.2.22#hostname`, and that hostname is the identity.
function stripComments(text) {
  return str(text).split("\n").filter(function(line) { return !/^\s*[#;]/.test(line) }).join("\n")
}

// The probe arrives in labelled sections: the same endpoint means different
// things by which config holds it. An undelimited blob is read as the stub's.
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

// Richest form first, so a match reports the transport actually in use.
function deviceIdentities(device) {
  var out = []
  if (device.dot !== "") out.push({ value: device.dot, transport: "DNS-over-TLS" })
  if (device.doh !== "") out.push({ value: device.doh, transport: "DNS-over-HTTPS" })
  return out.concat(
    device.v6.map(function(v) { return { value: v, transport: "IPv6" } }),
    device.v4.map(function(v) { return { value: v, transport: "IPv4" } }))
}

// Which of this account's devices this machine resolves through, and which
// config says so. Matching the device list rather than a hostname pattern is
// what lets the IPv6 and legacy IPv4 resolvers name the endpoint too: they
// carry the device id in an address, not in a name.
function matchEndpoint(devices, text) {
  var probe = probeSections(text)
  var list = devices || []
  for (var r = 0; r < RESOLVERS.length; r++) {
    var section = probe[RESOLVERS[r].key]
    if (section === "") continue
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

// Control D answering with no device matched: a legacy shared resolver, another
// account's endpoint, or an unreadable device list. Distinct from no Control D.
function controldPresent(text) {
  return CONTROLD_MARKER.test(stripComments(text))
}

// Whether Control D is what this machine resolves through now, rather than
// something a config file mentions. What the pause switch is really asking.
function controldLive(text) {
  var probe = probeSections(text)
  return CONTROLD_MARKER.test(probe.resolved) || CONTROLD_MARKER.test(probe.resolvconf)
}

// The account keeps a `ctrld` block on a device long after the daemon is gone,
// so whether one runs here is only answerable on the machine.
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

// Nothing says what manages the endpoint: the panel offers to have it reported.
function resolverUnknown(source) {
  return source === "resolvconf"
}

function normalizeDevice(d) {
  var profile = d.profile && typeof d.profile === "object" ? d.profile : {}
  var resolvers = d.resolvers && typeof d.resolvers === "object" ? d.resolvers : {}
  var ctrld = d.ctrld && typeof d.ctrld === "object" ? d.ctrld : null
  return {
    id: str(d.id),
    name: str(d.name),
    profileId: str(profile.id),
    profileName: str(profile.name),
    status: str(d.status),
    ctrldVersion: ctrld ? str(ctrld.version) : "",
    analytics: d.analytics === undefined || d.analytics === null ? "" : str(d.analytics),
    dot: str(resolvers.dot),
    doh: str(resolvers.doh),
    v4: strList(resolvers.v4),
    v6: strList(resolvers.v6)
  }
}

function parseDevices(raw) {
  var r = parseList(raw, "device", function(d) {
    var device = normalizeDevice(d)
    return device.id === "" ? null : device
  })
  return { ok: r.ok, devices: r.items, error: r.error }
}

// One device, as `cdctl device update` echoes it back after verifying the
// write: the same shape as a list entry, so it can replace one outright.
function parseDevice(raw) {
  var parsed = parseJson(raw)
  if (!parsed.ok) return { ok: false, device: null, error: parsed.error }
  if (!parsed.value || typeof parsed.value !== "object" || parsed.value instanceof Array)
    return { ok: false, device: null, error: "not a device" }
  var device = normalizeDevice(parsed.value)
  if (device.id === "") return { ok: false, device: null, error: "device has no id" }
  // An id and nothing else means cdctl's shape moved. `deviceProtected` reads
  // an unknown status as protected, which would report the write's opposite.
  if (device.status === "") return { ok: false, device: null, error: "device has no status" }
  return { ok: true, device: device, error: "" }
}

function replaceDevice(devices, device) {
  var list = devices || []
  if (!device) return list
  return list.map(function(d) { return d.id === device.id ? device : d })
}

// Whether Control D is filtering for this device, as the account sees it. Only
// the two disabled states are a pause: "pending" has just never made a query.
function deviceProtected(device) {
  if (!device) return false
  return device.status !== "soft-disabled" && device.status !== "hard-disabled"
}

// "none" is the only answer that means no: an unreported level is unknown, and
// the fetch settles it.
function analyticsReadable(device) {
  return !!device && device.analytics !== "none"
}

// Why this panel has no endpoint to describe: no Control D resolver at all is a
// different story to one we cannot put a name to, and only the first is bare.
var ENDPOINT_PENDING = "pending"
var ENDPOINT_NONE = "none"
var ENDPOINT_UNKNOWN = "unknown"
var ENDPOINT_MACHINE = "machine"

function endpointState(resolverChecked, controldFound, devicesChecked, endpoint) {
  if (!resolverChecked) return ENDPOINT_PENDING
  // Proof outranks the marker heuristic below: a legacy v4 resolver names a
  // device without looking like Control D anywhere in the config.
  if (endpoint) return ENDPOINT_MACHINE
  if (!controldFound) return ENDPOINT_NONE
  // A resolver we cannot name. Either the device lookup has not answered yet,
  // or it answered and this endpoint is not in the account.
  return devicesChecked ? ENDPOINT_UNKNOWN : ENDPOINT_PENDING
}

// The profile the endpoint enforces when that is known, else the browsed
// selection: never one the machine is not actually using.
function activeProfile(profiles, endpointProfileId, selectedId) {
  var enforced = str(endpointProfileId)
  if (enforced !== "") {
    var list = profiles || []
    for (var i = 0; i < list.length; i++) if (list[i].id === enforced) return list[i]
  }
  return resolveProfile(profiles, selectedId)
}


// A failure keeps the full shape, zeroed and `ok: false`, so the panel reads it
// as no answer rather than drawing the zeros as counts.
function emptyStats(error) {
  return {
    ok: false, hours: 0, action: 0,
    totals: { all: 0, blocked: 0, bypassed: 0, redirected: 0 },
    series: [], domains: [], filters: [], networks: [], countries: [], error: error
  }
}

// scripts/stats.py fans the analytics calls into one document per (window,
// action) pair, so this only has to validate it.
function parseStats(raw) {
  var parsed = parseJson(raw)
  if (!parsed.ok || !parsed.value || typeof parsed.value !== "object")
    return emptyStats(parsed.error || "bad stats output")
  var v = parsed.value
  if (v.ok !== true) return emptyStats(str(v.error) || "analytics failed")
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
  var items = list instanceof Array ? list : []
  return items.filter(function(entry) { return entry && str(entry.value) !== "" })
    .map(function(entry) { return { value: str(entry.value), count: num(entry.count) } })
}

function parseSeries(list) {
  var items = list instanceof Array ? list : []
  return items.filter(function(bucket) { return !!bucket })
    .map(function(bucket) { return { time: str(bucket.time), total: num(bucket.total), blocked: num(bucket.blocked) } })
}

// The action the lists describe: the API's values, the dashboard's labels.
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

// One chip per verdict, every row under exactly one. Bypassed earns its own
// because those rows are actionable -- the glyph there blocks the host -- and
// "Others" is the only place a redirect or a spoof is ever visible.
function activityFilterOptions() {
  return [
    { value: "blocked", label: "Blocked" },
    { value: "bypassed", label: "Bypassed" },
    { value: "others", label: "Others" }
  ]
}

// A redirect or a spoof may be the only one all day, so the rare chip reaches
// further: at six hours it would report that none happened when one did.
function activityHours(filter) {
  return str(filter) === "others" ? 24 : 6
}

// The API takes `action[]` repeatedly, so even "Others" narrows server side: a
// page of a verdict, not the handful that survive a client-side sieve.
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

// One column for five- and six-digit counts: 9500 -> "9.5K", 21432 -> "21K".
// The decimal stops paying for itself once the whole number is two digits.
function formatCount(value) {
  var n = num(value)
  if (n < 1000) return String(n)
  var unit = n < 1000000 ? "K" : "M"
  var scaled = n < 1000000 ? n / 1000 : n / 1000000
  return (scaled < 10 ? scaled.toFixed(1) : Math.round(scaled)) + unit
}

function blockedShare(total, blocked) {
  var t = num(total)
  if (t <= 0) return ""
  return Math.round((num(blocked) / t) * 100) + "%"
}

// ISO 3166-1 alpha-2 to everyday country name, generated from the iso-codes package.
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

// Keep the code when we do not know it, rather than showing nothing.
function countryName(code) {
  var key = str(code).toUpperCase()
  if (key === "") return ""
  return COUNTRY_NAMES[key] || key
}

// Filter ids come back as slugs; the dashboard shows titles we do not have, so
// make the slug readable rather than inventing a name.
function filterLabel(value) {
  var name = str(value).replace(/^x-/, "").replace(/[-_]+/g, " ").trim()
  return name === "" ? "unknown" : name.charAt(0).toUpperCase() + name.slice(1)
}

// scripts/activity.py returns the endpoint's most recent lookups, newest first,
// with the rows for one host and verdict folded into one entry and a tally.
function parseActivity(raw) {
  var parsed = parseJson(raw)
  if (!parsed.ok || !parsed.value || typeof parsed.value !== "object")
    return { ok: false, queries: [], error: parsed.error || "bad activity output" }
  var v = parsed.value
  if (v.ok !== true) return { ok: false, queries: [], error: str(v.error) || "activity log failed" }
  var list = v.queries instanceof Array ? v.queries : []
  var out = list.filter(function(q) { return q && str(q.question) !== "" })
    .map(function(q) {
      return {
        time: str(q.time),
        question: str(q.question),
        action: num(q.action, -1),
        trigger: str(q.trigger),
        triggerValue: str(q.triggerValue),
        protocol: str(q.protocol),
        types: q.types instanceof Array ? q.types.map(str) : [],
        repeats: num(q.repeats, 1)
      }
    })
  return { ok: true, queries: out, error: "" }
}

// Analytics reports the verdict as an integer; the panel speaks cdctl's names.
function actionName(action) {
  switch (num(action, -1)) {
  case 0: return "block"
  case 1: return "bypass"
  case 2: return "redirect"
  case 3: return "spoof"
  default: return ""
  }
}

// Local time, since the reader is looking at what their own machine just did.
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
  if (query.repeats > 1) parts.push("x" + query.repeats)
  return parts.join(" · ")
}

// Rows the profile has since overruled. The log records lookups, so allowing a
// host leaves the ones it was blocked on standing in the blocked view.
function dropOverridden(queries, rules) {
  return (queries || []).filter(function(q) {
    var rule = findRule(rules, q.question)
    return rule === null || !rule.enabled || rule.action === actionName(q.action)
  })
}

// A row acted on is held even once the fetch drops it: bypassing a host stops
// it being blocked, so using the blocked view removes what you just used it on,
// and with it the only way back. Merged by time so the row keeps its place.
function mergeSticky(queries, sticky, actions) {
  var out = (queries || []).slice()
  var held = sticky || []
  var want = actions || []
  for (var i = 0; i < held.length; i++) {
    var q = held[i]
    // Only into the view whose verdict it is, not whatever is on screen.
    if (want.length > 0 && want.indexOf(q.action) === -1) continue
    var seen = out.some(function(row) { return row.question === q.question && row.action === q.action })
    if (!seen) out.push(q)
  }
  out.sort(function(a, b) { return str(b.time).localeCompare(str(a.time)) })
  return out
}

// The API does the real validation; this only keeps the obvious mistakes from
// becoming a failed request. A leading "*." is the only place a wildcard sits.
function validHostname(text) {
  var host = str(text).trim().toLowerCase()
  if (host === "" || host.length > 253 || /[\s\/:]/.test(host)) return false
  var body = host.indexOf("*.") === 0 ? host.substring(2) : host
  if (!/^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$/.test(body)) return false
  if (body.indexOf("..") !== -1) return false
  return body.indexOf(".") > 0
}

// The opposite of what happened to a row, for the two verdicts a custom rule
// can reverse. A redirect or spoof is already a rule; unmatched decided nothing.
function overrideAction(query) {
  if (!query) return ""
  if (query.action === 0) return "bypass"
  if (query.action === 1) return "block"
  return ""
}

// One spelling to compare by: the log reports whatever the resolver was asked,
// upper case or trailing dot included, and neither names a different host.
function canonicalHost(hostname) {
  return str(hostname).trim().toLowerCase().replace(/\.+$/, "")
}

// Exact matches only: a rule on the parent domain covers this host too, but it
// is not this host's rule and removing it would reach further than the row asked.
function findRule(rules, hostname) {
  var want = canonicalHost(hostname)
  if (want === "") return null
  var list = rules || []
  for (var i = 0; i < list.length; i++)
    if (canonicalHost(list[i].hostname) === want) return list[i]
  return null
}

// A host with a rule offers to have it taken away, whichever way the log now
// reads: once a bypass takes effect the row turns up bypassed, and inverting it
// there would turn an allow into a deny. Everything else offers the opposite.
function ruleIntent(query, rules) {
  var action = overrideAction(query)
  var host = canonicalHost(query ? query.question : "")
  if (action === "" || host === "") return { action: "", verb: "", hostname: "" }
  var rule = findRule(rules, host)
  if (rule === null) return { action: action, verb: "create", hostname: host }
  // The rule's own spelling, not the log's: this becomes an argv entry, and
  // cdctl removes the rule it names rather than the one we matched.
  return { action: rule.action, verb: "delete", hostname: rule.hostname }
}

// Removing a rule hands the host back to whatever else decides, which the panel
// cannot predict, so the glyph names the operation instead of a verdict.
var UNDO_GLYPH = "\udb81\udd4c"

// Toggling changes nothing about what a rule does, so these name the operation
// too: pause on a rule that is running, play on one that is not.
var PAUSE_GLYPH = "\udb80\udfe4"
var PLAY_GLYPH = "\udb81\udc0a"
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
