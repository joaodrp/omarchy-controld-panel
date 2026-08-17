// Unit tests for Model.js, run with `node test/model.test.js`.
// Model.js is a QML .js file (no exports), so it is evaluated into a shared
// scope the same way the QML engine does it.

const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")

const src = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8")
const M = {}
vm.runInNewContext(src + "\n;this.__exports = { parseJson, parseError, errorLine, elide, parseAuthStatus, parseProfiles, parseRules, parseFolders, resolveProfile, nextProfile, groupRules, flattenGroups, countRules, limitRuleRows, rulesCaption, activityFilterOptions, activityActionArg, actionGlyph, ruleDetail, profileDetail, accountLine, matchEndpoint, controldPresent, controldLive, ctrldActive, resolverLabel, resolverUnknown, parseDevices, findDevice, endpointLine, endpointState, ENDPOINT_PENDING, ENDPOINT_NONE, ENDPOINT_UNKNOWN, ENDPOINT_MACHINE, activeProfile, defaultActionLine, parseStats, formatCount, blockedShare, windowLabel, meterRatio, sparkPoints, filterLabel, countryName, actionTotal, parseActivity, actionName, clockTime, activityDetail, windowOptions, actionOptions, EXIT_AUTH };", M)
const m = M.__exports

// vm-realm arrays fail strict deepEqual on prototype identity; compare by value.
function same(a, b) { assert.equal(JSON.stringify(a), JSON.stringify(b)) }

const tests = []
function test(name, fn) { tests.push([name, fn]) }

test("parseError reads the cdctl JSON envelope", () => {
  const err = m.parseError(JSON.stringify({ error: { code: "auth.invalid", message: "token rejected", hint: "run cdctl auth login", retryable: false } }), 4)
  assert.equal(err.code, "auth.invalid")
  assert.equal(err.message, "token rejected")
  assert.equal(err.hint, "run cdctl auth login")
  assert.equal(err.exitCode, m.EXIT_AUTH)
})

test("parseError falls back to raw stderr", () => {
  const err = m.parseError("sh: cdctl: not found\n", 127)
  assert.equal(err.message, "sh: cdctl: not found")
  assert.equal(err.hint, "")
  assert.equal(err.retryable, false)
})

test("parseError marks exit 8 retryable", () => {
  assert.equal(m.parseError("timeout", 8).retryable, true)
})

test("errorLine elides long messages", () => {
  const long = "x".repeat(300)
  assert.equal(m.errorLine({ message: long }).length, 140)
  assert.equal(m.errorLine(null, "fallback"), "fallback")
  assert.equal(m.errorLine({ message: "" }, "fallback"), "fallback")
})

test("parseAuthStatus", () => {
  const a = m.parseAuthStatus('{"authenticated":true,"email":"a@b.c","region":"europe","token_source":"config"}')
  assert.equal(a.ok, true)
  assert.equal(a.authenticated, true)
  assert.equal(m.accountLine(a), "a@b.c · europe")
  assert.equal(m.accountLine({ authenticated: false }), "Not authenticated")
  assert.equal(m.parseAuthStatus("nope").ok, false)
})

const profilesJson = JSON.stringify([
  { id: "p1", name: "Home", enabled_rules: 9, enabled_filters: 8, enabled_services: 0, folders: 0, enabled: true, disabled_until: null, default_action: { action: "bypass", via: null, enabled: true }, updated: "2026-01-01T00:00:00Z" },
  { id: "p2", name: "Kids", enabled_rules: 1, enabled_filters: 1, enabled_services: 1, folders: 2, enabled: false, disabled_until: "2026-02-01T00:00:00Z", default_action: [], updated: "" },
  { name: "no id, dropped" }
])

test("parseProfiles normalizes and drops junk", () => {
  const r = m.parseProfiles(profilesJson)
  assert.equal(r.ok, true)
  assert.equal(r.profiles.length, 2)
  assert.equal(r.profiles[0].enabledRules, 9)
  assert.equal(r.profiles[0].defaultAction, "bypass")
  assert.equal(r.profiles[1].enabled, false)
  assert.equal(r.profiles[1].defaultAction, "bypass")
  assert.equal(m.profileDetail(r.profiles[0]), "9 rules · 8 filters · 0 services")
  assert.equal(m.profileDetail(r.profiles[1]), "1 rule · 1 filter · 1 service · disabled")
  assert.equal(m.parseProfiles("{}").ok, false)
})

test("resolveProfile prefers id, then name, then first", () => {
  const { profiles } = m.parseProfiles(profilesJson)
  assert.equal(m.resolveProfile(profiles, "p2").id, "p2")
  assert.equal(m.resolveProfile(profiles, "kids").id, "p2")
  assert.equal(m.resolveProfile(profiles, "Home").id, "p1")
  assert.equal(m.resolveProfile(profiles, "missing").id, "p1")
  assert.equal(m.resolveProfile(profiles, "").id, "p1")
  assert.equal(m.resolveProfile([], "p1"), null)
})

test("nextProfile wraps around", () => {
  const { profiles } = m.parseProfiles(profilesJson)
  assert.equal(m.nextProfile(profiles, "p1", 1).id, "p2")
  assert.equal(m.nextProfile(profiles, "p2", 1).id, "p1")
  assert.equal(m.nextProfile(profiles, "p1", -1).id, "p2")
  assert.equal(m.nextProfile(profiles, "unknown", 1).id, "p1")
  assert.equal(m.nextProfile([], "p1", 1), null)
})

const rulesJson = JSON.stringify([
  { hostname: "b.example", action: "block", via: null, via6: null, enabled: true, folder: null, folder_id: null, order: 2 },
  { hostname: "a.example", action: "spoof", via: "192.0.2.1", via6: null, enabled: false, folder: null, folder_id: 0, order: 1 },
  { hostname: "c.example", action: "bypass", via: null, via6: null, enabled: true, folder: "Ads", folder_id: 7, order: 3 },
  { hostname: "d.example", action: "redirect", via: "LHR", via6: null, enabled: true, folder: "Ghost", folder_id: 9, order: 4 }
])
const foldersJson = JSON.stringify([
  { id: 7, name: "Ads", action: "block", via: null, enabled: true, rules: 1 },
  { id: 8, name: "Empty", action: null, via: null, enabled: false, rules: 0 }
])

test("parseRules sorts by order and normalizes folder_id 0 to null", () => {
  const r = m.parseRules(rulesJson)
  assert.equal(r.ok, true)
  same(r.rules.map(x => x.hostname), ["a.example", "b.example", "c.example", "d.example"])
  assert.equal(r.rules[0].folderId, null)
  assert.equal(r.rules[0].via, "192.0.2.1")
  assert.equal(m.ruleDetail(r.rules[0]), "spoof · 192.0.2.1 · disabled")
  assert.equal(m.ruleDetail(r.rules[1]), "block")
  same(m.countRules(r.rules), { total: 4, enabled: 3 })
})

test("groupRules: root first, then folders in cdctl order, unknown folders by name", () => {
  const rules = m.parseRules(rulesJson).rules
  const folders = m.parseFolders(foldersJson).folders
  const groups = m.groupRules(rules, folders)
  same(groups.map(g => g.name), ["", "Ads", "Empty", "Ghost"])
  same(groups[0].rules.map(r => r.hostname), ["a.example", "b.example"])
  assert.equal(groups[1].folder.enabled, true)
  assert.equal(groups[2].rules.length, 0)
  assert.equal(groups[3].folder, null)
  const rows = m.flattenGroups(groups)
  same(rows.map(r => r.kind), ["rule", "rule", "folder", "rule", "folder", "folder", "rule"])
})

test("limitRuleRows caps rules, not rows, and drops headers left with nothing", () => {
  const rows = m.flattenGroups(m.groupRules(m.parseRules(rulesJson).rules, m.parseFolders(foldersJson).folders))
  same(rows.map(r => r.kind), ["rule", "rule", "folder", "rule", "folder", "folder", "rule"])

  // Two rules in, the "Ads" header has not earned its place yet.
  same(m.limitRuleRows(rows, 2).map(r => r.kind), ["rule", "rule"])
  // Three rules in, it has.
  same(m.limitRuleRows(rows, 3).map(r => r.kind), ["rule", "rule", "folder", "rule"])
  // Room for everything: the empty "Empty" folder keeps its header, which is
  // the whole point of showing empty folders.
  same(m.limitRuleRows(rows, 4).map(r => r.kind), rows.map(r => r.kind))
  same(m.limitRuleRows(rows, 99).map(r => r.kind), rows.map(r => r.kind))
  // No cap.
  same(m.limitRuleRows(rows, 0).map(r => r.kind), rows.map(r => r.kind))
  same(m.limitRuleRows(null, 3), [])
})

test("activityActionArg narrows the log server side, or does not", () => {
  same(m.activityFilterOptions().map(o => o.value), ["blocked", "all"])
  // Anything but "all" narrows, so an unset or junk filter still lands on the
  // verdict the section is for rather than showing everything.
  assert.equal(m.activityActionArg("blocked"), "0")
  assert.equal(m.activityActionArg(""), "0")
  assert.equal(m.activityActionArg("all"), "")
})

test("rulesCaption says what is hidden only when something is", () => {
  assert.equal(m.rulesCaption({ total: 0, enabled: 0 }, 0), "No custom rules in this profile.")
  assert.equal(m.rulesCaption({ total: 9, enabled: 8 }, 9), "8 of 9 enabled")
  assert.equal(m.rulesCaption({ total: 40, enabled: 31 }, 15), "showing 15 of 40 · 31 enabled")
})

test("groupRules with no folders", () => {
  const rules = m.parseRules(rulesJson).rules.slice(0, 2)
  const rows = m.flattenGroups(m.groupRules(rules, []))
  same(rows.map(r => r.kind), ["rule", "rule"])
})

// The probe the service runs, as Model sees it: one labelled section per
// resolver we know how to read.
const probe = (s) => Object.keys(s).map(k => `@@${k}\n${s[k]}\n`).join("")

const probedDevices = m.parseDevices(JSON.stringify({ body: { devices: [
  { device_id: "dev0000001", name: "laptop", status: 1, profile: { PK: "p1", name: "Home" },
    resolvers: { uid: "dev0000001", doh: "https://dns.controld.com/dev0000001",
      dot: "dev0000001.dns.controld.com",
      v6: ["2606:1a40:0:19:1111:2222:3333:0", "2606:1a40:1:19:1111:2222:3333:0"] } },
  { device_id: "dev0000002", name: "desktop", status: 1, profile: { PK: "p1", name: "Home" },
    resolvers: { uid: "dev0000002", doh: "https://dns.controld.com/dev0000002",
      dot: "dev0000002.dns.controld.com", v4: ["76.76.20.20"],
      v6: ["2606:1a40:0:9:4444:5555:6666:0"] } }
] } })).devices

function matched(text, devices) {
  const r = m.matchEndpoint(devices === undefined ? probedDevices : devices, text)
  return { id: r.device ? r.device.id : "", source: r.source, transport: r.transport }
}

test("matchEndpoint identifies the device by any resolver form it publishes", () => {
  // DoT hostname, the form systemd-resolved takes.
  same(matched(probe({ resolved: "Current DNS Server: 76.76.2.22#dev0000001.dns.controld.com" })),
    { id: "dev0000001", source: "resolved", transport: "DNS-over-TLS" })

  // DoH URL in ctrld's own config, with resolved only pointing at its listener.
  same(matched(probe({ resolved: "Current DNS Server: 127.0.0.1",
    ctrld: 'upstream = "https://dns.controld.com/dev0000001"' })),
    { id: "dev0000001", source: "ctrld", transport: "DNS-over-HTTPS" })

  // The device-unique IPv6 resolvers, which name the endpoint with no proxy at
  // all and which a hostname match cannot see.
  same(matched(probe({ resolvconf: "nameserver 2606:1a40:1:19:1111:2222:3333:0" })),
    { id: "dev0000001", source: "resolvconf", transport: "IPv6" })

  // A legacy IPv4 resolver, and a different device, so this is a real match and
  // not the first entry winning.
  same(matched(probe({ dnsmasq: "server=76.76.20.20" })),
    { id: "dev0000002", source: "dnsmasq", transport: "IPv4" })

  same(matched(probe({ stubby: 'tls_auth_name: "dev0000001.dns.controld.com"' })),
    { id: "dev0000001", source: "stubby", transport: "DNS-over-TLS" })

  // Nothing Control D anywhere.
  same(matched(probe({ resolved: "Current DNS Server: 1.1.1.1", resolvconf: "nameserver 1.1.1.1" })),
    { id: "", source: "", transport: "" })

  // No device list yet: nothing can be named, whatever the config says.
  same(matched(probe({ resolved: "dev0000001.dns.controld.com" }), []),
    { id: "", source: "", transport: "" })
})

test("matchEndpoint credits the config that owns the endpoint", () => {
  // Both name it. ctrld is the one actually talking to Control D; resolved is
  // downstream of it.
  same(matched(probe({ ctrld: "dev0000001.dns.controld.com",
    resolved: "dev0000001.dns.controld.com" })).source, "ctrld")
  // A manager's own config beats the stub file it generates.
  same(matched(probe({ nm: "dev0000001.dns.controld.com",
    resolvconf: "dev0000001.dns.controld.com" })).source, "nm")
})

test("controldPresent sees Control D even when no device matches", () => {
  // A device that is not in this account.
  assert.equal(m.controldPresent(probe({ resolved: "notmine.dns.controld.com" })), true)
  // Legacy shared resolvers, which carry no device id at all.
  assert.equal(m.controldPresent(probe({ resolvconf: "nameserver 76.76.2.11 p2.freedns.controld.com" })), true)
  // Control D's anycast addresses and IPv6 prefix.
  assert.equal(m.controldPresent(probe({ resolvconf: "nameserver 76.76.2.22" })), true)
  assert.equal(m.controldPresent(probe({ resolvconf: "nameserver 2606:1a40:0:5:1:2:3:0" })), true)
  assert.equal(m.controldPresent(probe({ resolvconf: "nameserver 1.1.1.1" })), false)
})

test("comments never count, but a DoT hostname is not a comment", () => {
  // `address#hostname` is how systemd-resolved writes DoT. Cutting at the hash
  // would throw away the only thing that names the endpoint.
  assert.equal(m.controldPresent(probe({ resolved: "Current DNS Server: 76.76.2.22#x.dns.controld.com" })), true)
  assert.equal(m.controldPresent(probe({ resolvconf: "# nameserver 76.76.2.22" })), false)
  assert.equal(m.controldPresent(probe({ nm: "; servers=76.76.2.22" })), false)
})

test("controldLive asks only what the machine resolves through", () => {
  const live = probe({ resolved: "Current DNS Server: 76.76.2.22#x.dns.controld.com" })
  assert.equal(m.controldLive(live), true)
  assert.equal(m.controldLive(probe({ resolvconf: "nameserver 2606:1a40:0:5:1:2:3:0" })), true)
  // The inert provider label: mentioned in a manager's config, not in use.
  const inert = probe({ nm: "servers=76.76.2.22,76.76.10.22", resolved: "Current DNS Server: 8.8.8.8" })
  assert.equal(m.controldPresent(inert), true)
  assert.equal(m.controldLive(inert), false)
})

test("ctrldActive answers from the machine, not from the account", () => {
  assert.equal(m.ctrldActive(probe({ daemon: "active" })), true)
  // Installed but not running is not in use.
  assert.equal(m.ctrldActive(probe({ daemon: "inactive" })), false)
  // "activating" is not yet answering queries.
  assert.equal(m.ctrldActive(probe({ daemon: "activating" })), false)
  assert.equal(m.ctrldActive(""), false)
})

test("resolverLabel names what talks to Control D, or admits it cannot", () => {
  assert.equal(m.resolverLabel("ctrld", true, "v1.5.5"), "ctrld v1.5.5")
  // A running daemon the account reports no version for.
  assert.equal(m.resolverLabel("ctrld", true, ""), "ctrld")
  // The account still carries a ctrld version for a device that no longer runs
  // one: the local probe wins, which is the whole point of this row.
  assert.equal(m.resolverLabel("resolved", false, "v1.5.5"), "systemd-resolved")
  assert.equal(m.resolverLabel("nm", false, ""), "NetworkManager")
  assert.equal(m.resolverLabel("dnscrypt", false, ""), "dnscrypt-proxy")
  assert.equal(m.resolverLabel("stubby", false, ""), "stubby")
  assert.equal(m.resolverLabel("unbound", false, ""), "unbound")
  assert.equal(m.resolverLabel("dnsmasq", false, ""), "dnsmasq")
  // Something wrote the stub and we cannot tell what: the honest answer, and
  // the one the panel offers to have reported.
  assert.equal(m.resolverLabel("resolvconf", false, ""), "unknown")
  assert.equal(m.resolverLabel("", false, ""), "--")
  assert.equal(m.resolverUnknown("resolvconf"), true)
  assert.equal(m.resolverUnknown("resolved"), false)
})

test("parseDevices reads the raw upstream body", () => {
  const raw = JSON.stringify({ body: { devices: [
    { PK: "abc123", device_id: "abc123", name: "laptop", status: 1, icon: "desktop-linux",
      profile: { PK: "p1", name: "Home" }, ctrld: { version: "v1.5.5" },
      resolvers: { uid: "abc123", dot: "abc123.dns.controld.com", doh: "https://dns.controld.com/abc123" } },
    { device_id: "def456", name: "phone", status: 0, profile: { PK: "p2", name: "Kids" }, ctrld: null, resolvers: {} },
    { name: "no id, dropped" }
  ] } })
  const r = m.parseDevices(raw)
  assert.equal(r.ok, true)
  assert.equal(r.devices.length, 2)
  assert.equal(r.devices[0].profileName, "Home")
  assert.equal(r.devices[0].ctrldVersion, "v1.5.5")
  assert.equal(r.devices[1].enabled, false)
  assert.equal(r.devices[1].ctrldVersion, "")
  assert.equal(m.parseDevices("{}").ok, false)
  assert.equal(m.parseDevices("nope").ok, false)
})

test("findDevice matches the endpoint id, and endpointLine reads it", () => {
  const devices = m.parseDevices(JSON.stringify({ body: { devices: [
    { device_id: "abc123", name: "laptop", profile: { PK: "p1", name: "Home" } }
  ] } })).devices
  assert.equal(m.findDevice(devices, "ABC123").name, "laptop")
  assert.equal(m.findDevice(devices, "missing"), null)
  assert.equal(m.findDevice(devices, ""), null)
  assert.equal(m.endpointLine(devices[0], "DNS-over-TLS"), "Home · DNS-over-TLS")
  assert.equal(m.endpointLine(devices[0], ""), "Home")
  assert.equal(m.endpointLine(null, "DNS-over-TLS"), "")
})

test("endpointState says why this machine has no endpoint", () => {
  const device = { id: "abc123", name: "laptop" }
  // Nothing answered yet.
  assert.equal(m.endpointState(false, false, false, null), m.ENDPOINT_PENDING)
  // Control D is answering but the device list is still out.
  assert.equal(m.endpointState(true, true, false, null), m.ENDPOINT_PENDING)
  // No Control D resolver here, so there is nothing to identify.
  assert.equal(m.endpointState(true, false, true, null), m.ENDPOINT_NONE)
  // Resolver and device agree.
  assert.equal(m.endpointState(true, true, true, device), m.ENDPOINT_MACHINE)
  // Control D is answering but no device matched: the lookup failed, or the
  // endpoint is not in this account. Distinct from having no resolver at all.
  assert.equal(m.endpointState(true, true, true, null), m.ENDPOINT_UNKNOWN)
  // A matched device outranks the marker heuristic. The legacy v4 resolvers
  // name a device without looking like Control D anywhere in the config, so
  // asking "does this look like Control D" first would deny an endpoint the
  // account positively identified.
  assert.equal(m.endpointState(true, false, true, device), m.ENDPOINT_MACHINE)
})

test("activeProfile prefers the endpoint's profile over the browsed one", () => {
  const { profiles } = m.parseProfiles(profilesJson)
  assert.equal(m.activeProfile(profiles, "p2", "p1").id, "p2")
  // No endpoint: fall back to the browsed selection, then to the first profile.
  assert.equal(m.activeProfile(profiles, "", "p2").id, "p2")
  assert.equal(m.activeProfile(profiles, "", "").id, "p1")
  // An endpoint on a profile this account no longer lists must not win.
  assert.equal(m.activeProfile(profiles, "gone", "p2").id, "p2")
  assert.equal(m.activeProfile([], "p1", "p1"), null)
})

test("defaultActionLine", () => {
  const { profiles } = m.parseProfiles(profilesJson)
  assert.equal(m.defaultActionLine(profiles[0]), "default: bypass")
  assert.equal(m.defaultActionLine(profiles[1]), "default: bypass · profile disabled")
  assert.equal(m.defaultActionLine(null), "")
})

test("parseStats validates the helper's document", () => {
  const raw = JSON.stringify({
    ok: true, hours: 24, action: 0,
    totals: { all: 21432, blocked: 6302, bypassed: 14709, redirected: 0 },
    series: [{ time: "t0", total: 100, blocked: 20 }, { time: "t1", total: 50, blocked: 10 }],
    domains: [{ value: "d.dropbox.com", count: 2112 }, { value: "", count: 9 }, { count: 3 }],
    filters: [{ value: "x-hagezi-proplus", count: 6288 }],
    networks: [{ value: "Google", count: 72 }],
    countries: [{ value: "US", count: 211 }]
  })
  const r = m.parseStats(raw)
  assert.equal(r.ok, true)
  assert.equal(r.totals.all, 21432)
  assert.equal(r.totals.bypassed, 14709)
  // Entries without a value are dropped rather than rendered blank.
  same(r.domains, [{ value: "d.dropbox.com", count: 2112 }])
  assert.equal(r.series.length, 2)
  assert.equal(m.actionTotal(r, 1), 14709)
  assert.equal(m.actionTotal(r, 0), 6302)
  // The helper reports its own failures in the same envelope.
  const failed = m.parseStats(JSON.stringify({ ok: false, error: "analytics unreachable: timed out" }))
  assert.equal(failed.ok, false)
  assert.equal(failed.error, "analytics unreachable: timed out")
  assert.equal(m.parseStats("").ok, false)
  assert.equal(m.parseStats("not json").ok, false)
})

test("meterRatio scales against the biggest row", () => {
  const rows = [{ count: 100 }, { count: 25 }, { count: 0 }]
  assert.equal(m.meterRatio(100, rows), 1)
  assert.equal(m.meterRatio(25, rows), 0.25)
  assert.equal(m.meterRatio(5, []), 0)
  assert.equal(m.meterRatio(5, [{ count: 0 }]), 0)
})

test("sparkPoints normalizes and flips the y axis", () => {
  same(m.sparkPoints([{ total: 10 }, { total: 5 }, { total: 0 }], "total"),
       [{ x: 0, y: 0 }, { x: 0.5, y: 0.5 }, { x: 1, y: 1 }])
  // One point cannot be a line, and an all-zero window must not divide by zero.
  same(m.sparkPoints([{ total: 4 }], "total"), [])
  same(m.sparkPoints([{ total: 0 }, { total: 0 }], "total"), [{ x: 0, y: 1 }, { x: 1, y: 1 }])
})

test("countryName spells codes out, keeping unknown ones", () => {
  assert.equal(m.countryName("PT"), "Portugal")
  assert.equal(m.countryName("us"), "United States")
  assert.equal(m.countryName("GB"), "United Kingdom")
  // An unmapped or empty code must not blank the row.
  assert.equal(m.countryName("ZZ"), "ZZ")
  assert.equal(m.countryName(""), "")
})

test("filterLabel makes a slug readable", () => {
  assert.equal(m.filterLabel("x-hagezi-proplus"), "Hagezi proplus")
  assert.equal(m.filterLabel("iot"), "Iot")
  assert.equal(m.filterLabel(""), "unknown")
})

test("formatCount, blockedShare, windowLabel", () => {
  assert.equal(m.formatCount(0), "0")
  assert.equal(m.formatCount(999), "999")
  assert.equal(m.formatCount(1000), "1.0K")
  assert.equal(m.formatCount(6302), "6.3K")
  assert.equal(m.formatCount(21432), "21K")
  assert.equal(m.formatCount(1250000), "1.3M")
  assert.equal(m.blockedShare(21432, 6302), "29%")
  assert.equal(m.blockedShare(0, 0), "")
  assert.equal(m.windowLabel(24), "last 24h")
  assert.equal(m.windowLabel(1), "last hour")
  assert.equal(m.windowLabel(168), "last 7d")
})

test("parseActivity reads the collapsed log", () => {
  const raw = JSON.stringify({ ok: true, queries: [
    { time: "2026-08-16T15:22:56.975Z", question: "p.controld.com", action: 0,
      trigger: "filter", triggerValue: "x-hagezi-proplus", protocol: "dot",
      types: ["AAAA", "A"], repeats: 2 },
    { question: "", action: 1 }
  ] })
  const r = m.parseActivity(raw)
  assert.equal(r.ok, true)
  assert.equal(r.queries.length, 1)
  assert.equal(r.queries[0].repeats, 2)
  // A host blocked over and over is one row and a count, not a screenful.
  assert.equal(m.activityDetail(r.queries[0]), "block · Hagezi proplus · AAAA/A · x2")
  assert.equal(m.activityDetail({ action: 0, trigger: "filter", triggerValue: "", types: [], repeats: 1 }),
               "block · filter")
  assert.equal(m.parseActivity(JSON.stringify({ ok: false, error: "analytics unreachable" })).error,
               "analytics unreachable")
  assert.equal(m.parseActivity("").ok, false)
})

test("actionName maps the analytics verdicts", () => {
  assert.equal(m.actionName(0), "block")
  assert.equal(m.actionName(1), "bypass")
  assert.equal(m.actionName(2), "redirect")
  // -1 is the log's "no verdict", and must not become a block.
  assert.equal(m.actionName(-1), "")
  assert.equal(m.actionName(99), "")
})

test("clockTime survives a bad timestamp", () => {
  assert.match(m.clockTime("2026-08-16T15:22:56.975Z"), /^\d\d:\d\d:\d\d$/)
  assert.equal(m.clockTime("not a date"), "")
  assert.equal(m.clockTime(""), "")
})

test("actionGlyph has a fallback", () => {
  assert.notEqual(m.actionGlyph("block"), m.actionGlyph("bypass"))
  assert.equal(m.actionGlyph("weird"), m.actionGlyph(""))
})

let failed = 0
for (const [name, fn] of tests) {
  try {
    fn()
    console.log("ok   " + name)
  } catch (e) {
    failed++
    console.log("FAIL " + name + "\n     " + String(e && e.message ? e.message : e))
  }
}
console.log(`${tests.length - failed}/${tests.length} passed`)
process.exit(failed === 0 ? 0 : 1)
