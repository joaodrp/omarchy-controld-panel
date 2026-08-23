import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Owns every cdctl process and the state the panel renders. Reads through the
// list commands; writes rules, the enforced profile and this device's status,
// each through cdctl with -y and verified by cdctl's own read-back.
Item {
  id: root

  property var settings: ({})

  property string cdctlPath: ""
  property bool installed: false
  property bool checkedInstall: false

  property bool authenticated: false
  property bool needsAuth: false
  property string email: ""
  property string region: ""

  property var profiles: []
  // The profile this endpoint enforces, and the only one the panel describes.
  readonly property var activeProfile: Model.activeProfile(profiles, enforcedProfileId, "")
  property var rules: []
  property var folders: []
  readonly property var groups: Model.groupRules(rules, folders)
  readonly property var ruleRows: Model.flattenGroups(groups)
  readonly property var visibleRuleRows: Model.limitRuleRows(ruleRows, ruleLimit)
  readonly property var ruleCount: Model.countRules(rules)
  readonly property int shownRuleCount: visibleRuleRows.filter(function(r) { return r.kind === "rule" }).length

  // This machine as Control D sees it, identified by the resolver it uses
  // rather than by its hostname. The probe is kept whole because only the
  // device list can read an identity out of it: a device publishes itself as a
  // DoT name, a DoH URL and its own addresses.
  property string resolverProbe: ""
  property var devices: []
  readonly property var endpointMatch: Model.matchEndpoint(devices, resolverProbe)
  readonly property var endpoint: endpointMatch.device
  readonly property string endpointTransport: endpointMatch.transport
  readonly property string resolverSource: endpointMatch.source
  readonly property bool ctrldActive: Model.ctrldActive(resolverProbe)
  readonly property string resolverLine: Model.resolverLabel(resolverSource, ctrldActive,
    endpoint ? endpoint.ctrldVersion : "")
  // The endpoint is named but nothing local says what manages it.
  readonly property bool resolverUnknown: endpoint !== null && Model.resolverUnknown(resolverSource)
  readonly property string endpointProfileId: endpoint ? endpoint.profileId : ""
  // Also true when no device matched: a legacy shared resolver, an endpoint
  // owned by another account, or a device list we could not read.
  readonly property bool usingControld: Model.controldPresent(resolverProbe)
  property bool resolverChecked: false
  // Separates "still loading" from "asked, and this endpoint is not one of ours".
  property bool devicesChecked: false
  property string devicesError: ""
  readonly property string endpointState: Model.endpointState(resolverChecked, usingControld, devicesChecked, endpoint)

  // Analytics for this endpoint. Fetched only while the panel is open: the
  // numbers are not visible otherwise, and they cost nine requests.
  property bool statsWanted: false
  property var stats: null
  property bool statsLoading: false
  property string statsError: ""
  property int statsHours: 24
  property int statsAction: 0
  property var statsCache: ({})
  property string _statsKey: ""
  readonly property bool statsAvailable: Model.analyticsReadable(endpoint)

  // The endpoint's recent lookups, polled faster than the rest and, like the
  // statistics, only while the panel is open. Blocked by default: that is the
  // verdict a site which will not load sends you looking for.
  property var activity: []
  // Set while the pointer is inside the list. A page that lands then is kept
  // back rather than dropped: the rows are choosing targets for a write, and
  // moving them under the pointer is how the wrong host gets a rule.
  property bool activityHeld: false
  property var _pendingActivity: null
  property string activityError: ""
  property string activityFilter: "blocked"
  property bool activityGrouped: true

  property bool refreshing: false
  property bool loadingRules: false
  property string lastError: ""
  property string lastHint: ""
  property string statusText: "Checking..."

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 120, 15, 3600)
  readonly property int statsWindowHours: intSetting("statsWindowHours", 24, 1, 720)
  readonly property bool statsEnabled: setting("showStatistics", true) !== false
  readonly property bool activityEnabled: setting("showActivity", true) !== false
  readonly property int activityRows: intSetting("activityRows", 10, 3, 20)
  // Standing Control D down has two answers, and the host's wins when these
  // are set. They are not equivalent: the host command changes what this
  // machine resolves through, the account changes what Control D does with
  // what it is asked. Only a machine with its own way of doing it configures
  // one, so the account is the fallback and every user gets the switch.
  readonly property string pauseCommand: String(setting("pauseCommand", "") || "").trim()
  readonly property string resumeCommand: String(setting("resumeCommand", "") || "").trim()
  readonly property bool hostPause: pauseCommand !== "" && resumeCommand !== ""
  // The host's own answer to whether Control D is on here; `dns-controld
  // --status` is one. Never `usingControld`, which is true of a config file
  // merely mentioning Control D and stays true through a pause.
  readonly property string statusCommand: String(setting("statusCommand", "") || "").trim()
  readonly property bool canPause: hostPause || endpoint !== null
  property bool pauseBusy: false
  property string pauseError: ""
  property string pendingRuleHost: ""
  property bool ruleBusy: false
  property string ruleError: ""
  // Rows held in the log because an override was applied to them, long enough
  // to take it back: bypassing a host is supposed to remove it from the
  // blocked view.
  property var stickyActivity: []
  // Overruled rows go, then the held ones come back: the row just acted on is
  // exactly the one a rule now contradicts.
  readonly property var activityLog: Model.mergeSticky(
    Model.dropOverridden(activity, rules), stickyActivity,
    Model.activityActions(activityFilter))
  property var _ruleIntent: null

  readonly property bool canEnforce: endpoint !== null && profiles.length > 1
  property bool enforceBusy: false
  property string enforceError: ""
  // What was just asked for, until the account confirms it. The write takes a
  // second or two, and a panel that says nothing for that long reads as a
  // click that missed.
  property string pendingProfileId: ""
  readonly property string enforcedProfileId: pendingProfileId !== "" ? pendingProfileId : endpointProfileId
  property int _statusExit: -1
  readonly property bool protectionObserved: {
    if (statusCommand !== "") return _statusExit === 0
    // The account cannot see a machine-local pause, so it only answers when the
    // account is also what the switch acts on.
    if (hostPause) return endpoint !== null || Model.controldLive(resolverProbe)
    return Model.deviceProtected(endpoint)
  }
  // What the user just asked for, until the machine agrees: the knob throws
  // immediately rather than after a systemd restart settles.
  property int _pauseDesired: -1
  property int _pauseSettles: 0
  readonly property bool protectionActive: _pauseDesired >= 0 ? _pauseDesired === 1 : protectionObserved

  readonly property int statsRows: intSetting("statsRows", 5, 3, 20)
  readonly property int ruleLimit: intSetting("ruleRows", 15, 5, 100)
  readonly property bool busy: lookupProcess.running || authProcess.running || profilesProcess.running || rulesProcess.running || foldersProcess.running || resolverProcess.running || devicesProcess.running
  readonly property bool ready: installed && authenticated && !needsAuth

  // Which profile a rules/folders fetch was launched for, so a switch mid-flight
  // discards the stale answer instead of showing another profile's rules.
  property string _rulesForProfile: ""
  property string _foldersForProfile: ""
  property bool _rulesPending: false
  property bool _foldersPending: false
  property var _pendingRules: null
  property var _pendingFolders: null

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  function cdctl(args) {
    // -q keeps info lines off stderr so a failure's stderr is only the JSON
    // envelope; --timeout bounds each request well inside the watchdog.
    return [cdctlPath, "--json", "-q", "--timeout", "15"].concat(args)
  }

  // The helper lives beside this file in the plugin directory.
  function scriptPath(name) {
    return String(Qt.resolvedUrl(name)).replace(/^file:\/\//, "")
  }

  // The endpoint belongs in the key: a machine whose resolver changes
  // mid-session would otherwise be shown the previous device's figures.
  function statsKey(hours, action) {
    return String(endpoint ? endpoint.id : "") + ":" + String(hours) + ":" + String(action)
  }

  function loadStats(force) {
    if (!statsEnabled || !statsAvailable || region === "") return
    var key = statsKey(statsHours, statsAction)
    var cached = statsCache[key]
    if (cached && force !== true) {
      stats = cached
      statsError = ""
      statsLoading = false
      return
    }
    if (statsProcess.running) return
    // The previous numbers stay on screen while the next window loads: a
    // section that empties and flashes back is worse than stale figures.
    statsLoading = true
    _statsKey = key
    statsProcess.command = ["python3", scriptPath("scripts/stats.py"),
      "--endpoint", endpoint.id,
      "--region", region,
      "--hours", String(statsHours),
      "--action", String(statsAction),
      "--top", String(statsRows)]
    statsProcess.running = true
  }

  function loadActivity() {
    if (!activityEnabled || !statsAvailable || region === "") return
    // Still running when the next tick arrives means stuck, and reaping it is
    // what keeps a wedged poll from stalling the section for good.
    reap(activityProcess)
    var args = ["python3", scriptPath("scripts/activity.py"),
      "--endpoint", endpoint.id,
      "--region", region,
      "--hours", String(Model.activityHours(activityFilter)),
      "--group", activityGrouped ? "host" : "lookup"]
    // The helper repeats these as `action[]`, so the page arrives narrowed.
    var actions = Model.activityActions(activityFilter)
    for (var i = 0; i < actions.length; i++) args = args.concat(["--action", String(actions[i])])
    activityProcess.command = args
    activityProcess.running = true
  }

  // A process we stop is not a process that failed, and empty output proves
  // neither: a kill and a crash before the first write look identical. The
  // stop is recorded here, and every handler asks `reaped` before trusting
  // what it collected.
  function reap(proc) {
    if (!proc.running) return
    proc.expectedStop = true
    proc.running = false
  }

  function reaped(proc) {
    var stopped = proc.expectedStop
    proc.expectedStop = false
    return stopped
  }

  component Reapable: Process {
    property bool expectedStop: false
    running: false
    command: []
  }

  component Collected: Reapable {
    property alias out: collectedOut.text
    property alias err: collectedErr.text
    stdout: StdioCollector { id: collectedOut; waitForEnd: true }
    stderr: StdioCollector { id: collectedErr; waitForEnd: true }
  }

  function setActivityFilter(value) {
    var next = String(value || "")
    if (next === "" || next === activityFilter) return
    activityFilter = next
    // The rows stay on screen while the next page loads: emptying the list
    // collapses the content height, which drags the scroll to the top.
    loadActivity()
  }

  // Point this machine's endpoint at another profile. `--enforce`, not the
  // global `--profile`: that one scopes which profile a command reads, and
  // cdctl rejects it here rather than half-applying the write.
  function setEnforcedProfile(profileId) {
    var id = String(profileId || "")
    if (endpoint === null || id === "" || id === enforcedProfileId || enforceBusy) return
    enforceBusy = true
    enforceError = ""
    pendingProfileId = id
    enforceProcess.command = cdctl(["-y", "device", "update", endpoint.id, "--enforce", id])
    writeWatchdog.restart()
    enforceProcess.running = true
  }

  // Every rule write. cdctl verifies each one by reading the profile back, so
  // a successful exit is the profile agreeing; the list is then refetched
  // rather than patched, because a rule carries an order and a folder the
  // panel does not choose.
  function startRuleWrite(hostname, args, intent) {
    ruleBusy = true
    ruleError = ""
    pendingRuleHost = hostname
    _ruleIntent = intent || null
    ruleProcess.command = cdctl(["-y"].concat(args))
    writeWatchdog.restart()
    ruleProcess.running = true
  }

  // Apply the override an activity row offers, or take it away again.
  function applyRuleIntent(intent) {
    if (!activeProfile || ruleBusy) return
    if (!intent || intent.verb === "" || intent.hostname === "") return
    var args = ["rule", intent.verb, intent.hostname, "--profile", activeProfile.id]
    if (intent.verb !== "delete") args = args.concat(["--action", intent.action])
    startRuleWrite(intent.hostname, args, intent)
  }

  // Hold the row just acted on, or let go of one whose override was undone.
  function holdActedRow(intent) {
    if (!intent) return
    var next = []
    for (var i = 0; i < stickyActivity.length; i++)
      if (stickyActivity[i].question !== intent.hostname) next.push(stickyActivity[i])
    if (intent.verb !== "delete") {
      for (var j = 0; j < activity.length; j++)
        if (activity[j].question === intent.hostname) { next.push(activity[j]); break }
    }
    stickyActivity = next
    if (next.length > 0) stickyTimer.restart()
    else stickyTimer.stop()
  }

  // Switch a rule off, or back on. Not delete: a rule here may be older than
  // this panel, and disabling it is undone in place, whereas removing it is not
  // recoverable from anything the panel shows.
  function toggleRule(rule) {
    if (!activeProfile || ruleBusy || !rule) return
    startRuleWrite(rule.hostname, ["rule", "update", rule.hostname,
      "--profile", activeProfile.id, rule.enabled ? "--disabled" : "--enabled"], null)
  }

  function createRule(hostname, action) {
    var host = String(hostname || "").trim().toLowerCase()
    if (!activeProfile || ruleBusy || !Model.validHostname(host)) return
    startRuleWrite(host, ["rule", "create", host,
      "--action", String(action || "block"), "--profile", activeProfile.id], null)
  }

  function deleteRule(rule) {
    if (!activeProfile || ruleBusy || !rule) return
    startRuleWrite(rule.hostname, ["rule", "delete", rule.hostname, "--profile", activeProfile.id], null)
  }

  function setProtection(on) {
    if (!canPause || pauseBusy) return
    _pauseDesired = on ? 1 : 0
    _pauseSettles = 0
    pauseBusy = true
    pauseError = ""
    if (hostPause) {
      // Through a shell, so the setting can be a real command line rather than
      // a bare path. It is the user's own config, run as they wrote it.
      pauseProcess.command = ["sh", "-c", on ? resumeCommand : pauseCommand]
      writeWatchdog.restart()
      pauseProcess.running = true
      return
    }
    devicePauseProcess.command = cdctl(["-y", "device", "update", endpoint.id,
      "--status", on ? "active" : "soft-disabled"])
    writeWatchdog.restart()
    devicePauseProcess.running = true
  }

  onActivityHeldChanged: {
    if (activityHeld || _pendingActivity === null) return
    activity = _pendingActivity
    _pendingActivity = null
  }

  onProtectionObservedChanged: {
    if (_pauseDesired >= 0 && protectionObserved === (_pauseDesired === 1)) {
      _pauseDesired = -1
      _pauseSettles = 0
    }
  }

  // One tick per probe. A command can exit 0 and change nothing, so the knob
  // gets a few rounds to be proved right and is then dropped: showing what was
  // asked for forever is worse than admitting it did not take.
  function noteProtectionProbe() {
    if (_pauseDesired < 0 || !hostPause) return
    if (protectionObserved === (_pauseDesired === 1)) {
      _pauseDesired = -1
      _pauseSettles = 0
      return
    }
    _pauseSettles++
    if (_pauseSettles < 3) return
    var wanted = _pauseDesired === 1
    _pauseDesired = -1
    _pauseSettles = 0
    pauseError = "The command ran, but Control D is still " + (wanted ? "off" : "on") + " here."
  }

  function setActivityGrouped(value) {
    if (value === activityGrouped) return
    activityGrouped = value
    loadActivity()
  }

  function setStatsWindow(hours) {
    var next = parseInt(String(hours), 10)
    if (!isFinite(next) || next === statsHours) return
    statsHours = next
    loadStats()
  }

  function setStatsAction(action) {
    var next = parseInt(String(action), 10)
    if (!isFinite(next) || next === statsAction) return
    statsAction = next
    loadStats()
  }

  function copyToClipboard(value) {
    var text = String(value || "")
    if (text === "") return
    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(text) + " | wl-copy"])
  }

  function refresh() {
    if (!checkedInstall) {
      if (!lookupProcess.running) {
        refreshing = true
        lookupProcess.running = true
      }
      return
    }
    if (!installed) return
    refreshing = true
    if (!authProcess.running) {
      authProcess.command = cdctl(["auth", "status"])
      authProcess.running = true
    }
    if (!profilesProcess.running) {
      profilesProcess.command = cdctl(["profile", "list"])
      profilesProcess.running = true
    }
    if (!resolverProcess.running) resolverProcess.running = true
    if (statusCommand !== "" && !statusProcess.running) {
      statusProcess.command = ["sh", "-c", statusCommand]
      statusProcess.running = true
    }
    if (statsWanted) { loadStats(true); loadActivity() }
    pollWatchdog.restart()
  }

  function loadRules(profileId) {
    var id = String(profileId || "")
    if (!installed || id === "") return
    loadingRules = true
    _pendingRules = null
    _pendingFolders = null
    // Both halves are refetched together and for the same profile. Skipping
    // whichever was still running let one profile's rules commit alongside
    // another's folders, which draws a coherent and entirely wrong list.
    reap(rulesProcess)
    reap(foldersProcess)
    _rulesForProfile = id
    _rulesPending = true
    rulesProcess.command = cdctl(["rule", "list", "--profile", id])
    rulesProcess.running = true
    _foldersForProfile = id
    _foldersPending = true
    foldersProcess.command = cdctl(["folder", "list", "--profile", id])
    foldersProcess.running = true
    // Restarted: an already-armed watchdog would reap these new processes with
    // whatever is left of its run.
    pollWatchdog.restart()
  }

  function setUnavailable(message, hint) {
    authenticated = false
    profiles = []
    rules = []
    folders = []
    statusText = message
    lastHint = hint || ""
  }

  // Every failure the panel paints also goes to the shell log, which is the
  // only thing a bug report can carry: `qs log -p "$OMARCHY_PATH/shell"`.
  function note(what, detail) {
    console.warn("controld:", what, String(detail || ""))
  }

  function writeError(label, text, exitCode, fallback) {
    var line = Model.errorLine(Model.parseError(text, exitCode), fallback)
    note(label, line)
    return line
  }

  // cdctl re-reads the device after writing and prints what it verified, so
  // the list takes that rather than waiting on a re-probe or another list.
  function acceptDevice(text) {
    var parsed = Model.parseDevice(text)
    if (!parsed.ok) return false
    devices = Model.replaceDevice(devices, parsed.device)
    return true
  }

  // A failed poll keeps the rows on screen and says why in the section itself,
  // never as a panel-wide error.
  function sectionError(parsed, text, fallback) {
    if (parsed.error !== "") return Model.elide(parsed.error, 120)
    var stderr = String(text || "").trim()
    return Model.elide(stderr !== "" ? stderr : fallback, 120)
  }

  // A write failure is only news until the panel has read the world again.
  // Otherwise the next open redisplays an error from ten minutes ago.
  function clearWriteErrors() {
    ruleError = ""
    pauseError = ""
    enforceError = ""
  }

  function applyError(err, fallback) {
    lastError = Model.errorLine(err, fallback)
    note(fallback, lastError)
    lastHint = err ? err.hint : ""
    if (err && err.exitCode === Model.EXIT_AUTH) {
      needsAuth = true
      authenticated = false
      statusText = "Not authenticated"
    }
  }

  function commitRules() {
    if (_rulesPending || _foldersPending) return
    loadingRules = false
    if (ruleBusy) {
      ruleBusy = false
      pendingRuleHost = ""
    }
    if (_pendingRules) rules = _pendingRules
    if (_pendingFolders) folders = _pendingFolders
  }

  Component.onCompleted: statsHours = statsWindowHours

  onStatsWindowHoursChanged: {
    statsCache = ({})
    statsHours = statsWindowHours
    if (statsWanted) loadStats()
  }

  onRegionChanged: if (statsWanted) { loadStats(); loadActivity() }
  onStatsAvailableChanged: if (statsWanted && statsAvailable) { loadStats(); loadActivity() }
  onStatsWantedChanged: if (statsWanted) { loadStats(); loadActivity() }

  onActiveProfileChanged: {
    if (activeProfile && activeProfile.id !== _rulesForProfile) loadRules(activeProfile.id)
  }

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    // A poll that never exits would block every later refresh, since each is
    // skipped while its process is still running.
    id: pollWatchdog
    interval: 25000
    repeat: false
    onTriggered: {
      var polls = [authProcess, profilesProcess, rulesProcess, foldersProcess,
        resolverProcess, devicesProcess, statsProcess, statusProcess]
      for (var i = 0; i < polls.length; i++) root.reap(polls[i])
      root.refreshing = false
      root.loadingRules = false
      root.statsLoading = false
    }
  }

  Timer {
    // A read that never returns is covered by the next poll, which overwrites
    // whatever it left behind. A write is not: the panel shows the state the
    // user asked for from the moment they ask, and only the write's own exit
    // takes that back. Without this the switch sits where it was put and the
    // hero names a profile nothing enforces, for as long as the shell runs.
    id: writeWatchdog
    interval: 30000
    repeat: false
    onTriggered: {
      // Only a process still running is one that failed to answer. `ruleBusy`
      // outlives its own write on purpose, waiting on the rules list to agree.
      if (ruleProcess.running) {
        root.reap(ruleProcess)
        root.ruleBusy = false
        root.pendingRuleHost = ""
        root._ruleIntent = null
        root.ruleError = "The rule write did not answer"
        root.note("rule write did not answer", ruleProcess.command.join(" "))
      }
      if (enforceProcess.running) {
        root.reap(enforceProcess)
        root.enforceBusy = false
        root.pendingProfileId = ""
        root.enforceError = "The profile switch did not answer"
        root.note("profile switch did not answer", enforceProcess.command.join(" "))
      }
      if (devicePauseProcess.running || pauseProcess.running) {
        root.reap(devicePauseProcess)
        root.reap(pauseProcess)
        root.pauseBusy = false
        root._pauseDesired = -1
        root.pauseError = "The pause command did not answer"
        root.note("pause did not answer", "")
      }
    }
  }

  Process {
    // The shell inherits Hyprland's environment, which usually lacks the cargo
    // and ~/.local bin dirs cdctl installs into.
    id: lookupProcess
    running: false
    command: ["sh", "-c",
      "if command -v cdctl >/dev/null 2>&1; then command -v cdctl; exit 0; fi; " +
      "for p in \"$HOME/.cargo/bin/cdctl\" \"$HOME/.local/bin/cdctl\" /usr/local/bin/cdctl /usr/bin/cdctl; do " +
      "if [ -x \"$p\" ]; then echo \"$p\"; exit 0; fi; done; exit 1"]
    stdout: StdioCollector { id: lookupStdout; waitForEnd: true }
    onExited: function(exitCode) {
      root.checkedInstall = true
      var path = String(lookupStdout.text || "").trim()
      root.installed = exitCode === 0 && path !== ""
      root.cdctlPath = root.installed ? path : ""
      if (root.installed) root.refresh()
      else {
        root.refreshing = false
        root.setUnavailable("cdctl not installed", "Install controld-cli and put cdctl on PATH")
      }
    }
  }

  Reapable {
    // Exit code only; the output is the host's business.
    id: statusProcess
    onExited: function(exitCode) {
      if (root.reaped(statusProcess)) return
      root._statusExit = exitCode
      root.noteProtectionProbe()
    }
  }

  Timer {
    // A resolver takes a moment to settle after the command returns, so the
    // panel re-probes rather than waiting for the next poll, minutes out.
    id: pauseSettleTimer
    interval: 3000
    repeat: true
    running: root._pauseDesired >= 0 && root.hostPause
    onTriggered: root.refresh()
  }

  Reapable {
    id: ruleProcess
    stderr: StdioCollector { id: ruleStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (root.reaped(ruleProcess)) return
      if (exitCode !== 0) {
        root.ruleBusy = false
        root.pendingRuleHost = ""
        root.ruleError = root.writeError("rule write failed", ruleStderr.text, exitCode,
          "Could not change this rule")
        return
      }
      root.ruleError = ""
      root.holdActedRow(root._ruleIntent)
      root._ruleIntent = null
      // Still busy: the write has landed, but the row goes on looking unacted
      // on until the rules it reads from agree, a second or two more.
      // `commitRules` releases it, so the glyph stays marked for the whole
      // operation rather than for the fast half of it.
      root.loadRules(root.activeProfile.id)
    }
  }

  Collected {
    id: enforceProcess
    onExited: function(exitCode) {
      if (root.reaped(enforceProcess)) return
      root.enforceBusy = false
      // Cleared either way: on success the device below carries the confirmed
      // profile, and on failure the panel falls back to what the account says.
      root.pendingProfileId = ""
      if (exitCode !== 0) {
        root.enforceError = root.writeError("profile switch failed", enforceProcess.err, exitCode,
          "Could not switch this device's profile")
        return
      }
      if (!root.acceptDevice(enforceProcess.out)) root.enforceError = "Could not read this device back"
    }
  }

  Collected {
    id: devicePauseProcess
    onExited: function(exitCode) {
      if (root.reaped(devicePauseProcess)) return
      root.pauseBusy = false
      root._pauseDesired = -1
      if (exitCode !== 0) {
        root.pauseError = root.writeError("device pause failed", devicePauseProcess.err, exitCode,
          "Could not change this device")
        return
      }
      if (!root.acceptDevice(devicePauseProcess.out)) root.pauseError = "Could not read this device back"
    }
  }

  Reapable {
    // The host's own way of standing Control D down and bringing it back. It
    // may need a password, so the command is expected to escalate itself.
    id: pauseProcess
    stderr: StdioCollector { id: pauseStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (root.reaped(pauseProcess)) return
      root.pauseBusy = false
      if (exitCode !== 0) {
        root._pauseDesired = -1
        root.pauseError = root.writeError("pause command failed", pauseStderr.text, exitCode,
          "The pause command failed")
      }
      // Re-probe: the resolver is the only thing that says whether it worked.
      root.refresh()
    }
  }

  Reapable {
    // Where this machine's DNS actually points, one section per resolver the
    // panel can read. An endpoint configured any other way still shows up
    // under `resolvconf`, which reports itself as unknown rather than guessing.
    id: resolverProcess
    command: ["sh", "-c",
      "echo @@ctrld; cat /etc/controld/ctrld.toml /etc/ctrld.toml 2>/dev/null; " +
      "echo @@stubby; cat /etc/stubby/stubby.yml 2>/dev/null; " +
      "echo @@dnscrypt; cat /etc/dnscrypt-proxy/dnscrypt-proxy.toml 2>/dev/null; " +
      "echo @@unbound; cat /etc/unbound/unbound.conf /etc/unbound/unbound.conf.d/*.conf 2>/dev/null; " +
      "echo @@dnsmasq; cat /etc/dnsmasq.conf /etc/dnsmasq.d/* 2>/dev/null; " +
      "echo @@nm; cat /etc/NetworkManager/NetworkManager.conf /etc/NetworkManager/conf.d/*.conf 2>/dev/null; " +
      "echo @@resolved; resolvectl status 2>/dev/null; " +
      "echo @@resolvconf; cat /etc/resolv.conf 2>/dev/null; " +
      "echo @@daemon; systemctl is-active ctrld 2>/dev/null"]
    stdout: StdioCollector { id: resolverStdout; waitForEnd: true }
    onExited: {
      if (root.reaped(resolverProcess)) return
      root.resolverProbe = resolverStdout.text
      root.resolverChecked = true
      // Fetched whether or not the probe looks like Control D: a device
      // publishes itself as addresses too, and only the account knows them.
      if (!devicesProcess.running) {
        root.devicesChecked = false
        devicesProcess.command = root.cdctl(["device", "list"])
        devicesProcess.running = true
      }
    }
  }

  Collected {
    // A failure here costs every machine-specific section, so it is reported.
    id: devicesProcess
    onExited: function(exitCode) {
      if (root.reaped(devicesProcess)) return
      root.devicesChecked = true
      if (exitCode !== 0) {
        root.devices = []
        root.devicesError = Model.errorLine(Model.parseError(devicesProcess.err, exitCode), "Could not read your devices")
      } else {
        var parsed = Model.parseDevices(devicesProcess.out)
        root.devices = parsed.ok ? parsed.devices : []
        root.devicesError = parsed.ok ? "" : "Could not read your devices"
      }
      // The end of the probe chain. With a status command, that one ticks.
      if (root.statusCommand === "") root.noteProtectionProbe()
    }
  }

  Timer {
    // One window for every held row rather than one each: the last of them is
    // what the reader is still looking at.
    id: stickyTimer
    interval: 10000
    repeat: false
    // Letting go moves every row beneath, so it waits for the pointer too.
    onTriggered: {
      if (root.activityHeld) { stickyTimer.restart(); return }
      root.stickyActivity = []
    }
  }

  Timer {
    // The log is only worth anything fresh, and it is one request.
    id: activityTimer
    interval: 15000
    repeat: true
    running: root.statsWanted && root.activityEnabled && root.statsAvailable
    onTriggered: root.loadActivity()
  }

  Collected {
    id: activityProcess
    onExited: function(exitCode) {
      if (root.reaped(activityProcess)) return
      var parsed = Model.parseActivity(activityProcess.out)
      if (!parsed.ok) {
        root.activityError = root.sectionError(parsed, activityProcess.err, "activity unavailable")
        return
      }
      if (root.activityHeld) root._pendingActivity = parsed.queries
      else root.activity = parsed.queries
      root.activityError = ""
    }
  }

  Collected {
    // Analytics is a different origin than the REST API, so this goes through
    // the plugin's own helper rather than cdctl.
    id: statsProcess
    onExited: function(exitCode) {
      root.statsLoading = false
      if (root.reaped(statsProcess)) return
      var parsed = Model.parseStats(statsProcess.out)
      if (!parsed.ok) {
        root.stats = null
        root.statsError = root.sectionError(parsed, statsProcess.err, "statistics unavailable")
        return
      }
      var next = Object.assign({}, root.statsCache)
      next[root._statsKey] = parsed
      root.statsCache = next
      // A slow answer for a window the user has already left must not overwrite
      // what they are looking at now.
      if (root._statsKey === root.statsKey(root.statsHours, root.statsAction)) {
        root.stats = parsed
        root.statsError = ""
      }
    }
  }

  Collected {
    id: authProcess
    onExited: function(exitCode) {
      if (root.reaped(authProcess)) return
      if (exitCode !== 0) {
        var err = Model.parseError(authProcess.err, exitCode)
        root.applyError(err, "cdctl auth status failed")
        if (err.exitCode !== Model.EXIT_AUTH) root.statusText = "Unavailable"
        return
      }
      var parsed = Model.parseAuthStatus(authProcess.out)
      if (!parsed.ok) {
        root.applyError(null, "Could not read cdctl auth status")
        return
      }
      root.authenticated = parsed.authenticated
      root.needsAuth = !parsed.authenticated
      root.email = parsed.email
      root.region = parsed.region
      root.statusText = Model.accountLine(parsed)
      if (root.needsAuth) root.lastHint = "Run: cdctl auth login --token-stdin"
    }
  }

  Collected {
    id: profilesProcess
    onExited: function(exitCode) {
      root.refreshing = false
      if (root.reaped(profilesProcess)) return
      if (exitCode !== 0) {
        root.applyError(Model.parseError(profilesProcess.err, exitCode), "Could not list profiles")
        return
      }
      var parsed = Model.parseProfiles(profilesProcess.out)
      if (!parsed.ok) {
        root.applyError(null, "Could not read profile list")
        return
      }
      root.lastError = ""
      root.lastHint = ""
      root.needsAuth = false
      root.profiles = parsed.profiles
      if (root.activeProfile) root.loadRules(root.activeProfile.id)
      else {
        root.rules = []
        root.folders = []
      }
    }
  }

  Collected {
    id: rulesProcess
    onExited: function(exitCode) {
      root._rulesPending = false
      if (root.reaped(rulesProcess) || !root.activeProfile
        || root._rulesForProfile !== root.activeProfile.id) { root.commitRules(); return }
      if (exitCode !== 0) {
        root.applyError(Model.parseError(rulesProcess.err, exitCode), "Could not list rules")
        root._pendingRules = []
      } else {
        var parsed = Model.parseRules(rulesProcess.out)
        if (!parsed.ok) root.applyError(null, "Could not read rule list")
        root._pendingRules = parsed.ok ? parsed.rules : []
      }
      root.commitRules()
    }
  }

  Collected {
    id: foldersProcess
    onExited: function(exitCode) {
      root._foldersPending = false
      if (root.reaped(foldersProcess) || !root.activeProfile
        || root._foldersForProfile !== root.activeProfile.id) { root.commitRules(); return }
      if (exitCode !== 0) {
        root.applyError(Model.parseError(foldersProcess.err, exitCode), "Could not list folders")
        root._pendingFolders = []
      } else {
        var parsed = Model.parseFolders(foldersProcess.out)
        // Reported like every sibling parse: dropping it leaves foldered rules
        // under a heading `groupRules` invents from the id, and nothing said.
        if (!parsed.ok) root.applyError(Model.parseError(parsed.error, exitCode), "Could not read folders")
        root._pendingFolders = parsed.ok ? parsed.folders : []
      }
      root.commitRules()
    }
  }
}
