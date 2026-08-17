import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Owns every cdctl process and the state the panel renders. Read-only: it
// lists, it never writes.
Item {
  id: root

  property var settings: ({})

  // Resolved once; "" until the lookup runs, and stays "" when cdctl is absent.
  property string cdctlPath: ""
  property bool installed: false
  property bool checkedInstall: false

  property bool authenticated: false
  property bool needsAuth: false
  property string email: ""
  property string region: ""

  property var profiles: []
  // The profile this machine's endpoint enforces, which is the only one the
  // panel describes.
  readonly property var activeProfile: Model.activeProfile(profiles, endpointProfileId, "")
  property var rules: []
  property var folders: []
  readonly property var groups: Model.groupRules(rules, folders)
  readonly property var ruleRows: Model.flattenGroups(groups)
  readonly property var visibleRuleRows: Model.limitRuleRows(ruleRows, ruleLimit)
  readonly property var ruleCount: Model.countRules(rules)
  readonly property int shownRuleCount: {
    var n = 0
    for (var i = 0; i < visibleRuleRows.length; i++) if (visibleRuleRows[i].kind === "rule") n++
    return n
  }

  // This machine as Control D sees it, resolved from the DNS resolver it is
  // actually using rather than from its hostname. The probe text is kept whole
  // because the device list is what turns it into an identity: a device
  // publishes itself as a DoT name, a DoH URL and its own addresses, and only
  // the account knows which are which.
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
  // Control D is answering here even when no device matched: a legacy shared
  // resolver, an endpoint owned by another account, or a device list we could
  // not read.
  readonly property bool usingControld: Model.controldPresent(resolverProbe)
  readonly property bool resolverChecked: _resolverChecked
  property bool _resolverChecked: false
  // Whether the device lookup has answered, which is what separates "still
  // loading" from "asked, and this endpoint is not one of ours".
  property bool devicesChecked: false
  property string devicesError: ""
  readonly property string endpointState: Model.endpointState(resolverChecked, usingControld, devicesChecked, endpoint)

  // Analytics for this endpoint. Fetched only while the panel is open: the
  // numbers are not visible otherwise, and they cost three requests.
  property bool statsWanted: false
  property var stats: null
  property bool statsLoading: false
  property string statsError: ""
  // The window and the verdict the lists describe, both driven from the panel.
  property int statsHours: 24
  property int statsAction: 0
  // Answers are cached per window and action so flipping a tab back is free.
  property var statsCache: ({})
  property string _statsKey: ""
  readonly property int endpointAnalytics: endpoint ? endpoint.analytics : 0
  readonly property bool statsAvailable: endpoint !== null && endpointAnalytics > 0

  // The endpoint's most recent lookups. Polled only while the panel is open,
  // and faster than the rest, since "recent" is the whole point. Filtered to
  // blocked by default: that is the verdict worth reading, and the one a site
  // that will not load sends you looking for.
  property var activity: []
  property bool activityLoading: false
  property string activityError: ""
  property string activityFilter: "blocked"
  // Fold every row for a host into one with a tally, rather than keeping each
  // lookup. On by default: which hosts were blocked is what the section is for.
  property bool activityGrouped: true

  property bool refreshing: false
  property bool loadingRules: false
  property string lastError: ""
  property string lastHint: ""
  property string statusText: "Checking…"

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 120, 15, 3600)
  readonly property int statsWindowHours: intSetting("statsWindowHours", 24, 1, 720)
  readonly property bool statsEnabled: setting("showStatistics", true) !== false
  readonly property bool activityEnabled: setting("showActivity", true) !== false
  readonly property int activityRows: intSetting("activityRows", 10, 3, 20)
  // Rows per statistics list (domains, filters, destinations), and the cap on
  // the rules list. Every list in the panel is a top-N; these are the Ns.
  // Pausing is host specific: there is no one way to stand Control D down, so
  // the panel runs whatever the host says instead of guessing. Both empty, the
  // hero shows no switch and the panel stays read-only.
  readonly property string pauseCommand: String(setting("pauseCommand", "") || "").trim()
  readonly property string resumeCommand: String(setting("resumeCommand", "") || "").trim()
  readonly property bool canPause: pauseCommand !== "" && resumeCommand !== ""
  property bool pauseBusy: false
  property string pauseError: ""
  // What the user just asked for, until the resolver probe agrees. The knob
  // throws immediately rather than after a systemd restart settles.
  property int _pauseDesired: -1
  readonly property bool protectionActive: _pauseDesired >= 0 ? _pauseDesired === 1 : usingControld

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

  // `cdctl api` emits the upstream body verbatim and rejects --json.
  function cdctlApi(path) {
    return [cdctlPath, "-q", "--timeout", "15", "api", path]
  }

  // The helper lives beside this file in the plugin directory.
  function scriptPath(name) {
    return String(Qt.resolvedUrl(name)).replace(/^file:\/\//, "")
  }

  function statsKey(hours, action) {
    return String(hours) + ":" + String(action)
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
    // Keep the previous numbers on screen while the next window loads; an
    // empty section that flashes back is worse than slightly stale figures.
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
    // Still running when the next tick arrives means it is stuck; reaping it
    // here is what keeps a wedged poll from stalling the section for good.
    reap(activityProcess)
    activityLoading = true
    // How many to keep is the helper's business: it hands back a whole page so
    // the panel can expand into it without asking again.
    var args = ["python3", scriptPath("scripts/activity.py"),
      "--endpoint", endpoint.id,
      "--region", region]
    var action = Model.activityActionArg(activityFilter)
    if (action !== "") args = args.concat(["--action", action])
    args = args.concat(["--group", activityGrouped ? "host" : "lookup"])
    activityProcess.command = args
    activityProcess.running = true
  }

  // A process we stop is not a process that failed. Empty output is not proof
  // of that: a kill or a crash before the first write looks identical.
  function reap(proc) {
    if (!proc.running) return
    proc.expectedStop = true
    proc.running = false
  }

  function setActivityFilter(value) {
    var next = String(value || "")
    if (next === "" || next === activityFilter) return
    activityFilter = next
    // Leave the rows on screen while the next page loads. Emptying the list
    // collapses the panel's content height, which drags the scroll to the top
    // and loses the reader's place.
    loadActivity()
  }

  function setProtection(on) {
    if (!canPause || pauseBusy) return
    _pauseDesired = on ? 1 : 0
    pauseBusy = true
    pauseError = ""
    // Through a shell, so the setting can be a real command line rather than a
    // bare path. It is the user's own config, run as they wrote it.
    pauseProcess.command = ["sh", "-c", on ? resumeCommand : pauseCommand]
    pauseProcess.running = true
  }

  onUsingControldChanged: {
    // The probe has caught up with what was asked for, so stop overriding it.
    if (_pauseDesired >= 0 && usingControld === (_pauseDesired === 1)) _pauseDesired = -1
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
    if (statsWanted) { loadStats(true); loadActivity() }
    if (!pollWatchdog.running) pollWatchdog.start()
  }

  function loadRules(profileId) {
    var id = String(profileId || "")
    if (!installed || id === "") return
    loadingRules = true
    _pendingRules = null
    _pendingFolders = null
    if (!rulesProcess.running) {
      _rulesForProfile = id
      _rulesPending = true
      rulesProcess.command = cdctl(["rule", "list", "--profile", id])
      rulesProcess.running = true
    }
    if (!foldersProcess.running) {
      _foldersForProfile = id
      _foldersPending = true
      foldersProcess.command = cdctl(["folder", "list", "--profile", id])
      foldersProcess.running = true
    }
    if (!pollWatchdog.running) pollWatchdog.start()
  }

  function setUnavailable(message, hint) {
    authenticated = false
    profiles = []
    rules = []
    folders = []
    statusText = message
    lastHint = hint || ""
  }

  function applyError(err, fallback) {
    lastError = Model.errorLine(err, fallback)
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
    if (_pendingRules) rules = _pendingRules
    if (_pendingFolders) folders = _pendingFolders
  }

  // The endpoint resolves after the first rules fetch, so the rules follow it
  // once it lands rather than staying on the browsed profile.
  // The endpoint lands after the panel has already opened, so the first fetch
  // usually happens here rather than on open.
  Component.onCompleted: statsHours = statsWindowHours

  // A fresh window setting resets the runtime choice and everything cached.
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
    // A poll that never exits would otherwise block every later refresh, since
    // each is skipped while its process is still running.
    id: pollWatchdog
    interval: 25000
    repeat: false
    onTriggered: {
      root.reap(authProcess)
      root.reap(profilesProcess)
      root.reap(rulesProcess)
      root.reap(foldersProcess)
      root.reap(resolverProcess)
      root.reap(devicesProcess)
      root.reap(statsProcess)
      root.refreshing = false
      root.loadingRules = false
      root.statsLoading = false
    }
  }

  Process {
    // The shell inherits Hyprland's environment, which usually lacks the
    // cargo and ~/.local bin dirs cdctl installs into.
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

  Process {
    // The host's own way of standing Control D down and bringing it back. It
    // may need a password, so the command is expected to escalate itself.
    id: pauseProcess
    running: false
    command: []
    stderr: StdioCollector { id: pauseStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.pauseBusy = false
      if (exitCode !== 0) {
        root._pauseDesired = -1
        root.pauseError = Model.errorLine(Model.parseError(pauseStderr.text, exitCode),
          "The pause command failed")
      }
      // Re-probe: the resolver is the only thing that says whether it worked.
      root.refresh()
    }
  }

  Process {
    // Where this machine's DNS actually points, and what is doing the pointing.
    // Sections are labelled because the answer depends on which config holds
    // the endpoint, and because a running ctrld is a fact about this machine
    // that the account's device record outlives.
    id: resolverProcess
    property bool expectedStop: false
    running: false
    // One section per resolver the panel can read. The list is deliberately
    // short: these are the documented Linux setups, and an endpoint found
    // anywhere else still shows up under `resolvconf`, which reports itself as
    // unknown rather than guessing.
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
      root.resolverProbe = resolverStdout.text
      var reaped = expectedStop
      expectedStop = false
      if (reaped) return
      root._resolverChecked = true
      // The device list is what turns the probe into an identity, so it is
      // fetched whether or not the probe looks like Control D: a device
      // publishes itself as addresses too, and only the account knows them.
      if (!devicesProcess.running) {
        root.devicesChecked = false
        devicesProcess.command = cdctlApi("/devices")
        devicesProcess.running = true
      }
    }
  }

  Process {
    // The escape hatch: `cdctl api` emits the upstream body verbatim, so this
    // reads raw API field names. A failure here costs the panel every
    // machine-specific section, so the reason is kept rather than swallowed.
    id: devicesProcess
    property bool expectedStop: false
    running: false
    command: []
    stdout: StdioCollector { id: devicesStdout; waitForEnd: true }
    stderr: StdioCollector { id: devicesStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var reaped = expectedStop
      expectedStop = false
      if (reaped) return
      root.devicesChecked = true
      if (exitCode !== 0) {
        root.devices = []
        root.devicesError = Model.errorLine(Model.parseError(devicesStderr.text, exitCode), "Could not read your devices")
        return
      }
      var parsed = Model.parseDevices(devicesStdout.text)
      root.devices = parsed.ok ? parsed.devices : []
      root.devicesError = parsed.ok ? "" : "Could not read your devices"
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

  Process {
    id: activityProcess
    property bool expectedStop: false
    running: false
    command: []
    stdout: StdioCollector { id: activityStdout; waitForEnd: true }
    stderr: StdioCollector { id: activityStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.activityLoading = false
      var reaped = expectedStop
      expectedStop = false
      if (reaped) return
      var parsed = Model.parseActivity(activityStdout.text)
      if (parsed.ok) {
        root.activity = parsed.queries
        root.activityError = ""
        return
      }
      // Keep the rows already on screen: a failed poll should not blank a log
      // the user is reading.
      var stderr = String(activityStderr.text || "").trim()
      root.activityError = Model.elide(parsed.error !== "" ? parsed.error : (stderr !== "" ? stderr : "activity unavailable"), 120)
    }
  }

  Process {
    // Analytics is a different origin than the REST API, so this goes through
    // the plugin's own helper rather than cdctl. Failures are reported in the
    // section itself, never as a panel-wide error.
    id: statsProcess
    property bool expectedStop: false
    running: false
    command: []
    stdout: StdioCollector { id: statsStdout; waitForEnd: true }
    stderr: StdioCollector { id: statsStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.statsLoading = false
      var reaped = expectedStop
      expectedStop = false
      if (reaped) return
      var parsed = Model.parseStats(statsStdout.text)
      if (parsed.ok) {
        var next = ({})
        for (var key in root.statsCache) next[key] = root.statsCache[key]
        next[root._statsKey] = parsed
        root.statsCache = next
        // A slow answer for a window the user has already left must not
        // overwrite what they are looking at now.
        if (root._statsKey === root.statsKey(root.statsHours, root.statsAction)) {
          root.stats = parsed
          root.statsError = ""
        }
        return
      }
      root.stats = null
      var stderr = String(statsStderr.text || "").trim()
      root.statsError = Model.elide(parsed.error !== "" ? parsed.error : (stderr !== "" ? stderr : "statistics unavailable"), 120)
    }
  }

  Process {
    id: authProcess
    property bool expectedStop: false
    running: false
    command: []
    stdout: StdioCollector { id: authStdout; waitForEnd: true }
    stderr: StdioCollector { id: authStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var reaped = expectedStop
      expectedStop = false
      if (reaped) return
      if (exitCode === 0) {
        var parsed = Model.parseAuthStatus(authStdout.text)
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
      } else {
        var err = Model.parseError(authStderr.text, exitCode)
        root.applyError(err, "cdctl auth status failed")
        if (err.exitCode !== Model.EXIT_AUTH) root.statusText = "Unavailable"
      }
    }
  }

  Process {
    id: profilesProcess
    property bool expectedStop: false
    running: false
    command: []
    stdout: StdioCollector { id: profilesStdout; waitForEnd: true }
    stderr: StdioCollector { id: profilesStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.refreshing = false
      var reaped = expectedStop
      expectedStop = false
      if (reaped) return
      if (exitCode !== 0) {
        root.applyError(Model.parseError(profilesStderr.text, exitCode), "Could not list profiles")
        return
      }
      var parsed = Model.parseProfiles(profilesStdout.text)
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

  Process {
    id: rulesProcess
    property bool expectedStop: false
    running: false
    command: []
    stdout: StdioCollector { id: rulesStdout; waitForEnd: true }
    stderr: StdioCollector { id: rulesStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root._rulesPending = false
      var reaped = expectedStop
      expectedStop = false
      if (reaped) { root.commitRules(); return }
      if (!root.activeProfile || root._rulesForProfile !== root.activeProfile.id) { root.commitRules(); return }
      if (exitCode !== 0) {
        root.applyError(Model.parseError(rulesStderr.text, exitCode), "Could not list rules")
        root._pendingRules = []
      } else {
        var parsed = Model.parseRules(rulesStdout.text)
        if (parsed.ok) root._pendingRules = parsed.rules
        else {
          root.applyError(null, "Could not read rule list")
          root._pendingRules = []
        }
      }
      root.commitRules()
    }
  }

  Process {
    id: foldersProcess
    property bool expectedStop: false
    running: false
    command: []
    stdout: StdioCollector { id: foldersStdout; waitForEnd: true }
    stderr: StdioCollector { id: foldersStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root._foldersPending = false
      var reaped = expectedStop
      expectedStop = false
      if (reaped) { root.commitRules(); return }
      if (!root.activeProfile || root._foldersForProfile !== root.activeProfile.id) { root.commitRules(); return }
      if (exitCode !== 0) {
        root.applyError(Model.parseError(foldersStderr.text, exitCode), "Could not list folders")
        root._pendingFolders = []
      } else {
        var parsed = Model.parseFolders(foldersStdout.text)
        root._pendingFolders = parsed.ok ? parsed.folders : []
      }
      root.commitRules()
    }
  }
}
