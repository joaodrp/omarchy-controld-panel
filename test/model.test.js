// Unit tests for Model.js, run with `node test/model.test.js`.
// Model.js is a QML .js file (no exports), so it is evaluated into a shared
// scope the same way the QML engine does it.

const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")

const src = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8")
const M = {}
vm.runInNewContext(src + "\n;this.__exports = { parseJson, parseError, errorLine, elide, parseAuthStatus, parseProfiles, parseRules, parseFolders, resolveProfile, nextProfile, groupRules, flattenGroups, countRules, actionGlyph, ruleDetail, profileDetail, accountLine, EXIT_AUTH };", M)
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

test("groupRules with no folders", () => {
  const rules = m.parseRules(rulesJson).rules.slice(0, 2)
  const rows = m.flattenGroups(m.groupRules(rules, []))
  same(rows.map(r => r.kind), ["rule", "rule"])
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
