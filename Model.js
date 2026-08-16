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
    // 0 none, 1 some, 2 full — analytics is off for this endpoint at 0.
    analytics: num(d.stats, 0),
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

// Second line of the endpoint's profile row.
function defaultActionLine(profile) {
  if (!profile) return ""
  var parts = ["default: " + actionLabel(profile.defaultAction)]
  if (!profile.enabled) parts.push("profile disabled")
  return parts.join(" · ")
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

function actionOptions() {
  return [
    { value: String(ACTION_BLOCKED), label: "Blocked" },
    { value: String(ACTION_BYPASSED), label: "Bypassed" },
    { value: String(ACTION_REDIRECTED), label: "Redirected" }
  ]
}

function actionTotal(stats, action) {
  if (!stats) return 0
  var a = num(action)
  if (a === ACTION_BYPASSED) return stats.totals.bypassed
  if (a === ACTION_REDIRECTED) return stats.totals.redirected
  return stats.totals.blocked
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

// Sparkline geometry: normalized 0..1 points, y already flipped for QML's
// downward axis, so the caller only scales by width and height.
function sparkPoints(series, key) {
  var items = series || []
  if (items.length < 2) return []
  var field = key || "total"
  var max = 0
  for (var i = 0; i < items.length; i++) max = Math.max(max, num(items[i][field]))
  var points = []
  for (var j = 0; j < items.length; j++) {
    points.push({
      x: j / (items.length - 1),
      y: max > 0 ? 1 - (num(items[j][field]) / max) : 1
    })
  }
  return points
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

// Caption for the statistics section: the window it covers.
function windowLabel(hours) {
  var h = num(hours, 24)
  if (h <= 1) return "last hour"
  if (h < 48) return "last " + h + "h"
  var days = Math.round(h / 24)
  return "last " + days + "d"
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
