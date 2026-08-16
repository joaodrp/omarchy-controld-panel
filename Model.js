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
    enabledRules: num(p.enabled_rules),
    enabledFilters: num(p.enabled_filters),
    enabledServices: num(p.enabled_services),
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

function nextProfile(profiles, currentId, delta) {
  var list = profiles || []
  if (list.length === 0) return null
  var index = -1
  for (var i = 0; i < list.length; i++) if (list[i].id === str(currentId)) { index = i; break }
  if (index === -1) return list[0]
  var step = delta === undefined ? 1 : delta
  return list[((index + step) % list.length + list.length) % list.length]
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
  var total = 0, enabled = 0
  var list = rules || []
  for (var i = 0; i < list.length; i++) {
    total++
    if (list[i].enabled) enabled++
  }
  return { total: total, enabled: enabled }
}

// This machine's Control D endpoint is identified by the resolver it is
// actually using: every device's DoT hostname and DoH path carry its own
// device id, so `<uid>.dns.controld.com` or `dns.controld.com/<uid>` in the
// local DNS config names the endpoint exactly. Legacy shared resolvers
// (p1/p2/family.freedns.controld.com) carry no id and match nothing.
function resolverUid(text) {
  var haystack = str(text)
  var dot = haystack.match(/\b([a-z0-9]{6,})\.dns\.controld\.com\b/i)
  if (dot) return { uid: dot[1].toLowerCase(), transport: "DNS-over-TLS" }
  var doh = haystack.match(/dns\.controld\.com\/([a-z0-9]{6,})\b/i)
  if (doh) return { uid: doh[1].toLowerCase(), transport: "DNS-over-HTTPS" }
  return { uid: "", transport: "" }
}

function normalizeDevice(d) {
  var profile = d && d.profile && typeof d.profile === "object" ? d.profile : {}
  var resolvers = d && d.resolvers && typeof d.resolvers === "object" ? d.resolvers : {}
  var ctrld = d && d.ctrld && typeof d.ctrld === "object" ? d.ctrld : null
  return {
    id: str(d.device_id) || str(d.PK),
    name: str(d.name),
    profileId: str(profile.PK),
    profileName: str(profile.name),
    enabled: num(d.status, 1) === 1,
    icon: str(d.icon),
    ctrldVersion: ctrld ? str(ctrld.version) : "",
    dot: str(resolvers.dot),
    doh: str(resolvers.doh)
  }
}

// `cdctl api /devices` is the escape hatch, so this reads the upstream body
// verbatim rather than the CLI's normalized schema.
function parseDevices(raw) {
  var parsed = parseJson(raw)
  if (!parsed.ok) return { ok: false, devices: [], error: parsed.error }
  var body = parsed.value && parsed.value.body ? parsed.value.body : null
  var list = body && body.devices instanceof Array ? body.devices : null
  if (!list) return { ok: false, devices: [], error: "no devices in response" }
  var out = []
  for (var i = 0; i < list.length; i++) {
    var d = list[i]
    if (!d || typeof d !== "object") continue
    var device = normalizeDevice(d)
    if (device.id !== "") out.push(device)
  }
  return { ok: true, devices: out, error: "" }
}

function findDevice(devices, uid) {
  var want = str(uid).toLowerCase()
  if (want === "") return null
  var list = devices || []
  for (var i = 0; i < list.length; i++) if (list[i].id.toLowerCase() === want) return list[i]
  return null
}

// Hero meta when this machine's endpoint is known: what it enforces and how.
function endpointLine(device, transport) {
  if (!device) return ""
  var parts = []
  if (device.profileName !== "") parts.push(device.profileName)
  if (str(transport) !== "") parts.push(str(transport))
  return parts.length > 0 ? parts.join(" · ") : "Control D"
}

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

// Second line of a profile row.
function profileDetail(profile) {
  if (!profile) return ""
  var parts = []
  parts.push(profile.enabledRules + (profile.enabledRules === 1 ? " rule" : " rules"))
  parts.push(profile.enabledFilters + (profile.enabledFilters === 1 ? " filter" : " filters"))
  parts.push(profile.enabledServices + (profile.enabledServices === 1 ? " service" : " services"))
  if (!profile.enabled) parts.push("disabled")
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
