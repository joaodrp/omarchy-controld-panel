import QtQuick
import QtQuick.Shapes
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.joaodrp.controld"
  ipcTarget: "io.github.joaodrp.controld"
  manageIpc: false

  // The cursor walks one flat list of rows in document order, so j/k does the
  // same thing wherever it is.
  property string cursorKey: ""
  property bool cursorActive: false
  // Where the cursor was, so a row retired by a poll does not send it home.
  property int lastCursorIndex: 0

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  // What is chosen, as against where the cursor is: one highlight would say
  // both at once.
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "transparent"

  // Every section hangs off this machine's endpoint, so without one there is
  // nothing to show and the panel says why instead.
  readonly property bool machineMode: controld.endpointState === Model.ENDPOINT_MACHINE
  readonly property bool showEndpoint: controld.ready && machineMode
  readonly property bool showRules: controld.ready && machineMode && controld.activeProfile !== null
  // No Control D resolver at all: the only state that means this machine is
  // unprotected.
  readonly property bool unprotected: controld.ready && controld.endpointState === Model.ENDPOINT_NONE
  // A Control D resolver we cannot put a name to: the device lookup failed, or
  // the endpoint belongs to another account. Protected, but not describable.
  readonly property bool endpointUnknown: controld.ready && controld.endpointState === Model.ENDPOINT_UNKNOWN
  readonly property string guideUrl: "https://github.com/joaodrp/omarchy-controld-panel#readme"
  readonly property string dashboardUrl: "https://controld.com/dashboard"
  // Where an unrecognised setup goes, so the next person with it is covered.
  readonly property string issuesUrl: "https://github.com/joaodrp/omarchy-controld-panel/issues"
  readonly property bool showEmptyState: (controld.checkedInstall && !controld.installed)
    || (controld.installed && controld.needsAuth)
    || unprotected || endpointUnknown
  readonly property bool showActivity: controld.ready && machineMode && controld.activityEnabled
    && (controld.activityLog.length > 0 || controld.activityError !== "")
  readonly property bool showStats: controld.ready && machineMode && controld.statsEnabled
    && (controld.statsAvailable || controld.statsError !== "")
  property bool legendOpen: false
  // While the picker is open the cursor walks its rows and nothing else:
  // picking one is a write, so drifting off it and pressing enter should not
  // be possible.
  property bool profilePickerOpen: false
  // Which row's glyph the pointer is on, by host rather than by row. Writing a
  // rule rebuilds the list, and a rebuilt delegate's MouseArea reports no
  // hover -- the pointer never entered it, it was created underneath one. Held
  // by host, the reach survives the rebuild it causes.
  property string hoveredGlyphHost: ""
  // Kept apart from the activity log's: a rule's hostname and a row's question
  // can be the same string, and reaching for one should not light the other.
  property string hoveredRuleHost: ""
  // A legend that lists what does nothing here is worse than none.
  readonly property var legendKeys: {
    var keys = [{ key: "j/k", what: "move" }, { key: "enter", what: "activate" }, { key: "y", what: "copy" }]
    if (showStats) keys.push({ key: "s", what: "statistics" })
    if (showActivity) keys.push({ key: "a", what: "activity" })
    if (showActivity) keys.push({ key: "b/B", what: "bypass/block" })
    if (showRules) keys.push({ key: "r", what: "rules" })
    if (showRules) keys.push({ key: "x", what: "rule on/off" })
    if (showEndpoint) keys.push({ key: "m", what: "machine" })
    if (controld.canEnforce) keys.push({ key: "p", what: "profile" })
    keys.push({ key: "g/G", what: "top/bottom" }, { key: "o", what: "dashboard" },
      { key: "R", what: "refresh" }, { key: "A", what: "ask agent" },
      { key: "esc", what: "close" })
    return keys
  }

  // Rows past the fold are already fetched, so expanding costs only space.
  property bool activityExpanded: false
  readonly property var visibleActivity: {
    var all = controld.activityLog
    if (activityExpanded || all.length <= controld.activityRows) return all
    return all.slice(0, controld.activityRows)
  }
  readonly property int hiddenActivity: controld.activityLog.length - visibleActivity.length
  readonly property bool activityExpandable: hiddenActivity > 0 || activityExpanded

  property string destinationView: "networks"
  readonly property var destinationRows: {
    if (!controld.stats) return []
    return destinationView === "countries" ? controld.stats.countries : controld.stats.networks
  }
  readonly property var actionRows: controld.stats ? controld.stats.domains : []
  readonly property string actionWord: {
    var a = controld.statsAction
    if (a === 1) return "bypassed"
    if (a === 2) return "redirected"
    return "blocked"
  }
  // Each chip says nothing happened in its own words: "no queries yet" is
  // wrong on a tab that is simply the rare one.
  readonly property string emptyActivityLine: {
    if (controld.activityFilter === "bypassed") return "nothing bypassed in this window"
    if (controld.activityFilter === "others") return "no redirects or spoofs in this window"
    return "nothing blocked in this window"
  }
  // The window chips already name the range, so this says only what they
  // cannot.
  readonly property string statsCaption: {
    if (!controld.statsAvailable) return "analytics off for this endpoint"
    if (controld.statsLoading) return "loading..."
    return ""
  }
  // Set from the list's own hover rather than from any row, so crossing the
  // gap between two rows does not count as leaving.
  onActivityHoveredChanged: controld.activityHeld = activityHovered
  readonly property bool activityHovered: activityColumn && activityHover.hovered
  readonly property var cursorRules: cursorRuleList()
  readonly property bool headerHasCursor: cursorActive && cursorKey === "header" && controld.installed
  readonly property color iconColor: controld.ready && !unprotected ? foreground : dim
  readonly property color barIconColor: controld.ready && !unprotected ? barForeground : Qt.darker(barForeground, 1.55)
  readonly property string heroTitle: controld.endpoint ? controld.endpoint.name : "Control D"
  readonly property string heroMeta: {
    if (!controld.installed) return "cdctl is not installed"
    if (controld.needsAuth) return "Not authenticated"
    if (controld.refreshing && !controld.authenticated) return "Checking..."
    // The caret is the only thing saying the profile can be changed: the
    // hero's meta is a plain string with nowhere to hang a control. The name
    // is the profile asked for rather than the one confirmed, so the hero
    // answers the click at once and the ellipsis carries the wait.
    if (controld.endpoint) {
      var name = controld.activeProfile ? controld.activeProfile.name : ""
      if (controld.enforceBusy) return name + "..."
      return name + (controld.canEnforce ? (profilePickerOpen ? " \udb80\udd43" : " \udb80\udd40") : "")
    }
    // The empty state below carries the reason, so the hero says which account
    // is signed in instead -- what the reader needs to act on it.
    return controld.email !== "" ? controld.email : controld.statusText
  }
  // Only what the rows cannot say for themselves.
  readonly property string rulesCaption: {
    if (controld.loadingRules && controld.rules.length === 0) return "Loading rules..."
    if (controld.ruleCount.total === 0) return "No custom rules in this profile."
    if (controld.shownRuleCount < controld.ruleCount.total)
      return "showing " + controld.shownRuleCount + " of " + controld.ruleCount.total
    return ""
  }

  // The cursor walks what is drawn, so a capped list does not leave keys
  // pointing at rules nobody can see.
  function cursorRuleList() {
    var rows = controld.visibleRuleRows
    var out = []
    for (var i = 0; i < rows.length; i++) if (rows[i].kind === "rule") out.push(rows[i].rule)
    return out
  }

  // Document order, so moving the cursor also walks the panel top to bottom.
  readonly property var cursorItems: {
    var items = [{ key: "header", kind: "header", value: "" }]
    if (profilePickerOpen) {
      for (var p = 0; p < controld.profiles.length; p++)
        items.push({ key: "profileOption:" + p, kind: "profileOption", index: p, value: "" })
      return items
    }
    if (showEndpoint && controld.endpoint)
      items.push({ key: "endpoint", kind: "endpoint", value: controld.endpoint.id })
    if (showStats && controld.stats) {
      for (var d = 0; d < controld.stats.domains.length; d++)
        items.push({ key: "domain:" + d, kind: "domain", index: d, value: controld.stats.domains[d].value })
      // Read, not acted on: the cursor visits them so j/k walks the panel
      // continuously, but they carry no value, so yank passes over them.
      for (var f = 0; f < controld.stats.filters.length; f++)
        items.push({ key: "filter:" + f, kind: "reading", index: f, value: "" })
      for (var t = 0; t < destinationRows.length; t++)
        items.push({ key: "destination:" + t, kind: "reading", index: t, value: "" })
    }
    if (showActivity) {
      for (var a = 0; a < visibleActivity.length; a++)
        items.push({ key: "activity:" + a, kind: "activity", index: a, value: visibleActivity[a].question })
      if (activityExpandable) items.push({ key: "activity:more", kind: "more", value: "" })
    }
    if (showRules) {
      for (var r = 0; r < cursorRules.length; r++)
        items.push({ key: "rule:" + r, kind: "rule", index: r, value: cursorRules[r].hostname })
    }
    return items
  }

  readonly property int cursorIndex: {
    for (var i = 0; i < cursorItems.length; i++) if (cursorItems[i].key === cursorKey) return i
    return -1
  }

  function currentCursor() {
    return cursorIndex >= 0 ? cursorItems[cursorIndex] : null
  }

  function ensureCursor() {
    // Polls rebuild the activity log and can change its length, retiring a key
    // like "activity:7". Falling back to the first row would throw the cursor
    // to the top of the panel mid-read, so it lands on the nearest surviving
    // row instead.
    if (cursorItems.length === 0) { cursorKey = ""; return }
    if (cursorIndex >= 0) { lastCursorIndex = cursorIndex; return }
    cursorKey = cursorItems[Math.max(0, Math.min(cursorItems.length - 1, lastCursorIndex))].key
  }

  function moveCursor(dy) {
    if (dy === 0) return
    ensureCursor()
    if (cursorItems.length === 0) return
    var next = cursorIndex < 0 ? 0 : cursorIndex + (dy > 0 ? 1 : -1)
    cursorKey = cursorItems[Math.max(0, Math.min(cursorItems.length - 1, next))].key
    cursorActive = true
    pointerGate.reset()
    scrollCursorIntoView()
  }

  // Yank, as vim means it: whatever the cursor is on. With no row under it,
  // the endpoint id is the one value on screen worth taking.
  function yank() {
    var entry = cursorActive ? currentCursor() : null
    if (entry && (entry.kind === "reading" || entry.kind === "more")) return
    if (entry && entry.kind !== "header" && String(entry.value || "") !== "") {
      controld.copyToClipboard(entry.value)
      return
    }
    if (controld.endpoint) controld.copyToClipboard(controld.endpoint.id)
  }

  // Copy is the only action most of these rows have.
  function activateCursor() {
    var entry = currentCursor()
    if (!entry) return
    if (entry.kind === "header") {
      // The mark is the dashboard link and `o` is its key, so the row itself
      // is free to carry the switch the caret advertises.
      if (controld.canEnforce) root.toggleProfilePicker()
      else Quickshell.execDetached(["omarchy-launch-browser", root.dashboardUrl])
      return
    }
    if (entry.kind === "profileOption") {
      controld.setEnforcedProfile(controld.profiles[entry.index].id)
      root.closeProfilePicker()
      return
    }
    if (entry.kind === "more") { root.toggleActivityExpanded(cursorItem()); return }
    if (entry.kind === "reading") return
    if (String(entry.value || "") !== "") controld.copyToClipboard(entry.value)
  }

  // The row already knows which override it offers, so the key only says which
  // verdict it meant: asking to bypass a host the log never blocked does
  // nothing rather than writing a rule the row was not offering.
  function applyRuleKey(action) {
    var entry = cursorActive ? currentCursor() : null
    if (!entry || entry.kind !== "activity") return
    var intent = Model.ruleIntent(visibleActivity[entry.index], controld.rules)
    if (intent.action !== action) return
    controld.applyRuleIntent(intent)
  }

  // The one row asking to be deleted, by host: a rule write rebuilds the list,
  // and a held object would outlive the row it came from. Opening another
  // question closes this one.
  property string pendingDeleteHost: ""
  // Block by default: a rule you go looking for is usually one you want
  // stopped, and a host you want allowed is normally already in the log with a
  // glyph offering it.
  property bool addRuleOpen: false
  property string addRuleAction: "block"

  // Pointers only: the account, the endpoint and the rules are all one `cdctl`
  // call away, so passing them would ship a snapshot that is stale on arrival
  // and put account identifiers in a terminal for nothing.
  function askAgent() {
    // `Qt.resolvedUrl("")` answers with nothing, so the plugin directory has to
    // come from a file that is in it.
    var skill = String(controld.scriptPath("agent/SKILL.md"))
    var dir = skill.replace(/\/agent\/SKILL\.md$/, "")
    var prompt = "I use the Control D panel in Omarchy's bar and I want help with it.\n\n"
      + "The plugin is at " + dir + "\n"
      + "Control D's account CLI is `cdctl`; `cdctl reference` prints its whole command "
      + "surface as one document. Everything about the account, this machine's endpoint, "
      + "its profile and its rules is readable from there -- read it rather than asking me.\n\n"
      + "Read " + skill + " and follow it."
    Quickshell.execDetached(["omarchy-agent", "--prompt", prompt])
  }

  function toggleAddRule() {
    addRuleOpen = !addRuleOpen
    if (!addRuleOpen) return
    // Nothing else should be mid-question while a new rule is being typed.
    pendingDeleteHost = ""
    addRuleHost.text = ""
    addRuleHost.forceActiveFocus()
    scrollItemIntoView(addRuleForm)
  }

  function submitAddRule() {
    if (!Model.validHostname(addRuleHost.text)) return
    controld.createRule(addRuleHost.text, addRuleAction)
    addRuleOpen = false
    addRuleHost.text = ""
  }

  function askDeleteRule(rule) {
    if (!rule || controld.ruleBusy) return
    pendingDeleteHost = pendingDeleteHost === rule.hostname ? "" : rule.hostname
  }

  function confirmDeleteRule() {
    var rule = Model.findRule(controld.rules, pendingDeleteHost)
    pendingDeleteHost = ""
    if (rule) controld.deleteRule(rule)
  }

  // Rules only: no other row has an off switch.
  function toggleRuleKey() {
    var entry = cursorActive ? currentCursor() : null
    if (!entry || entry.kind !== "rule") return
    controld.toggleRule(cursorRules[entry.index])
  }

  // Opening lands the cursor on the profile in force, so enter twice is a
  // no-op rather than a write to whatever sat first in the list.
  function openProfilePicker() {
    if (!controld.canEnforce) return
    profilePickerOpen = true
    var current = 0
    for (var i = 0; i < controld.profiles.length; i++)
      if (controld.profiles[i].id === controld.endpointProfileId) current = i
    setCursor("profileOption:" + current)
    cursorActive = true
  }

  function toggleProfilePicker() {
    if (profilePickerOpen) closeProfilePicker()
    else openProfilePicker()
  }

  function closeProfilePicker() {
    if (!profilePickerOpen) return
    profilePickerOpen = false
    setCursor("header")
  }

  // Collapsing takes rows out from above the row that did it, so everything
  // below slides up while the scroll offset stays put and the reader lands in
  // another section. Holding that row still makes the list shrink under it
  // rather than the panel move around it. Expanding needs none of this: the
  // new rows fill the space the row is pushed out of.
  function toggleActivityExpanded(anchor) {
    if (!activityExpanded) { activityExpanded = true; return }
    var before = -1
    if (panelFlick && anchor) {
      var y = anchor.mapToItem(panelFlick.contentItem, 0, 0).y
      // Only worth holding still if it is on screen. Rows folding away below
      // the fold move nothing the reader can see, and correcting for that is
      // itself the jump.
      if (y >= panelFlick.contentY && y <= panelFlick.contentY + panelFlick.height) before = y
    }
    activityExpanded = false
    if (before < 0) return
    Qt.callLater(function() {
      if (!panelFlick || !anchor) return
      var after = anchor.mapToItem(panelFlick.contentItem, 0, 0).y
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      panelFlick.contentY = Math.max(0, Math.min(maxY, panelFlick.contentY + (after - before)))
    })
  }

  function scrollItemIntoView(item) {
    if (!panelFlick || !item) return
    Qt.callLater(function() {
      if (!item) return
      var margin = Style.space(6)
      var point = item.mapToItem(panelFlick.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var viewTop = panelFlick.contentY
      var viewBottom = viewTop + panelFlick.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < viewTop + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  function sectionCursorPrefix(section) {
    if (section === machineSection) return "endpoint"
    if (section === statsSection) return "domain:"
    if (section === activitySection) return "activity:"
    if (section === rulesSection) return "rule:"
    return ""
  }

  // Section jumps: pin the section to the top of the view rather than
  // nudging it into sight, so the key lands somewhere predictable.
  function jumpTo(section) {
    if (!panelFlick || !section || !section.visible) return
    // Land the cursor there too, so j/k carries on from where the eye did.
    var prefix = sectionCursorPrefix(section)
    if (prefix !== "") {
      for (var i = 0; i < cursorItems.length; i++) {
        if (cursorItems[i].key.indexOf(prefix) === 0) {
          cursorKey = cursorItems[i].key
          cursorActive = true
          break
        }
      }
    }
    pointerGate.reset()
    var y = section.mapToItem(panelFlick.contentItem, 0, 0).y
    var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
    panelFlick.contentY = Math.max(0, Math.min(maxY, y - Style.space(8)))
  }

  function jumpToEdge(bottom) {
    if (!panelFlick) return
    cursorActive = false
    pointerGate.reset()
    panelFlick.contentY = bottom
      ? Math.max(0, panelFlick.contentHeight - panelFlick.height)
      : 0
  }

  // The item under the cursor. Rows carry their own key rather than sitting at
  // a known index: a Repeater's delegates share their parent with the Repeater
  // itself and any header, so counting children lands on the wrong one.
  function cursorItem() {
    var entry = currentCursor()
    if (!entry) return null
    if (entry.kind === "rule") return ruleRowItem(entry.index)
    if (entry.kind === "endpoint") return machineSection
    return findByCursorKey([domainList, filterList, destinationList, activityColumn], entry.key)
  }

  function findByCursorKey(containers, key) {
    for (var c = 0; c < containers.length; c++) {
      var container = containers[c]
      if (!container) continue
      for (var i = 0; i < container.children.length; i++) {
        var child = container.children[i]
        if (child && child.cursorKey === key) return child
      }
    }
    return null
  }

  function scrollCursorIntoView() {
    var entry = currentCursor()
    if (!entry) return
    if (entry.kind === "header") { panelFlick.contentY = 0; return }
    scrollItemIntoView(cursorItem())
  }

  // The rules column mixes folder headers and rules.
  function ruleRowItem(n) {
    if (!ruleColumn) return null
    var seen = 0
    for (var i = 0; i < ruleColumn.children.length; i++) {
      var child = ruleColumn.children[i]
      if (child && child.isRuleRow === true) {
        if (seen === n) return child
        seen++
      }
    }
    return null
  }

  // Pointing at a row selects it, as walking the cursor onto it does. Moving
  // the cursor by key scrolls the list under a stationary pointer, though, and
  // the row sliding beneath it would steal the cursor straight back -- so
  // pointer selection waits for the pointer to actually move.
  function setCursor(key) {
    cursorActive = true
    cursorKey = key
  }

  function setCursorFromPointer(key, item, mouse) {
    if (!pointerGate.moved(item, mouse)) return
    setCursor(key)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    controld.statsWanted = opened
    legendOpen = false
    profilePickerOpen = false
    if (!opened) return
    cursorActive = false
    cursorKey = "header"
    activityExpanded = false
    controld.clearWriteErrors()
    controld.stickyActivity = []
    controld.setActivityFilter("blocked")
    controld.setActivityGrouped(true)
    pointerGate.reset()
    if (panelFlick) panelFlick.contentY = 0
    controld.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  onCursorItemsChanged: ensureCursor()

  PointerMoveGate {
    id: pointerGate
    // A stable frame to measure against: rows move as the list scrolls, the
    // viewport does not.
    referenceItem: panelFlick
  }

  Service {
    id: controld
    settings: root.settings
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { controld.refresh(); return "ok" }
    function profile(): string { return controld.activeProfile ? controld.activeProfile.name : "" }
    function status(): string { return controld.statusText }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        ControldIcon {
          anchors.centerIn: parent
          // The height the rest of the bar's marks paint at.
          iconSize: Style.space(11)
          color: root.barIconColor
          badgeColor: root.urgent
          crossed: (controld.checkedInstall && !controld.installed) || root.unprotected
          warning: controld.installed && controld.needsAuth
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) controld.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: {
        // The strip answers first, then the picker, then the panel itself:
        // escape should undo the last thing opened, not the outermost.
        if (root.pendingDeleteHost !== "") root.pendingDeleteHost = ""
        else if (root.addRuleOpen) root.toggleAddRule()
        else if (root.profilePickerOpen) root.closeProfilePicker()
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        // The add form owns the letters while it is open: `b` belongs in a
        // hostname there, not on the row behind it.
        if (root.addRuleOpen) return
        if (t === "s") root.jumpTo(statsSection)
        else if (t === "a") root.jumpTo(activitySection)
        else if (t === "r") root.jumpTo(rulesSection)
        else if (t === "m") root.jumpTo(machineSection)
        else if (t === "g") root.jumpToEdge(false)
        else if (t === "G") root.jumpToEdge(true)
        else if (t === "?") root.legendOpen = !root.legendOpen
        else if (t === "p") root.toggleProfilePicker()
        else if (t === "o") Quickshell.execDetached(["omarchy-launch-browser", root.dashboardUrl])
        // Shift for the actions, since the plain letters name sections.
        else if (t === "R") controld.refresh()
        else if (t === "A") root.askAgent()
        else if (t === "y" || t === "Y") root.yank()
        // Shift for the heavier verdict, as `r`/`R` already reads here.
        else if (t === "b") root.applyRuleKey("bypass")
        else if (t === "B") root.applyRuleKey("block")
        else if (t === "x") root.toggleRuleKey()
      }

      Flickable {
        id: panelFlick
        anchors.left: parent.left
        anchors.right: parent.right
        // Reach into the card's padding so the scrollbar, which overlays the
        // right edge rather than taking space, sits in that gutter instead of
        // over the content. The column gives the width straight back.
        anchors.rightMargin: -panel.padding
        anchors.top: parent.top
        anchors.bottom: legend.visible ? legend.top : parent.bottom
        anchors.bottomMargin: legend.visible ? Style.space(8) : 0
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width - panel.padding
          spacing: Style.space(12)

          Item {
            width: parent.width
            implicitHeight: hero.implicitHeight

            // The caret on the meta line has nowhere of its own to take a
            // click: `PanelHero.meta` is a plain string. So the whole hero
            // carries it, declared first and therefore beneath the mark and
            // the switch, which keep their own clicks.
            MouseArea {
              anchors.fill: parent
              enabled: controld.canEnforce && controld.installed
              hoverEnabled: enabled
              cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
              onClicked: root.toggleProfilePicker()
            }

            PanelHero {
              id: hero
              width: parent.width
              title: root.heroTitle
              meta: root.heroMeta
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconOpacity: controld.ready ? 1.0 : 0.5
              // The dashboard is where everything this panel cannot do lives,
              // and the mark is the way there.
              iconComponent: Component {
                Item {
                  implicitWidth: heroMark.implicitWidth + Style.space(10)
                  implicitHeight: heroMark.implicitHeight + Style.space(10)

                  Rectangle {
                    anchors.fill: parent
                    radius: Style.cornerRadius
                    color: heroMarkMouse.containsMouse || root.headerHasCursor
                      ? root.hoverFill : "transparent"
                  }

                  ControldIcon {
                    id: heroMark
                    anchors.centerIn: parent
                    iconSize: Style.font.display
                    color: root.iconColor
                    badgeColor: root.urgent
                    crossed: (controld.checkedInstall && !controld.installed) || root.unprotected
                    warning: controld.installed && controld.needsAuth
                  }

                  MouseArea {
                    id: heroMarkMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Quickshell.execDetached(["omarchy-launch-browser", root.dashboardUrl])
                  }

                  PanelToolTip {
                    visible: heroMarkMouse.containsMouse
                    text: "Open Control D dashboard"
                    fontFamily: root.fontFamily
                  }
                }
              }

              // The only control here, and the one that has to survive there
              // being no endpoint to describe: pausing is what removed it.
              trailingControl: Component {
                ToggleSwitch {
                  id: protectionSwitch
                  visible: controld.canPause && controld.installed
                  checked: controld.protectionActive
                  busy: controld.pauseBusy
                  foreground: hero.foreground
                  // A control, not a row: reaching for it is deliberate, so
                  // its hover skips the pointer gate.
                  onHovered: function(on) { if (on) root.setCursor("header") }
                  onToggled: controld.setProtection(!controld.protectionActive)

                  PanelToolTip {
                    visible: protectionSwitch.containsMouse
                    text: controld.protectionActive ? "Pause Control D on this machine"
                      : "Resume Control D on this machine"
                    fontFamily: hero.fontFamily
                  }
                }
              }
            }
          }

          // Not while an empty state is up. Those say what happened and what
          // to do about it; the error line underneath them is the same failure
          // told worse, and in red.
          NoticeText {
            visible: controld.lastError !== "" && !root.showEmptyState
            text: controld.lastError
          }

          NoticeText {
            visible: controld.pauseError !== ""
            text: controld.pauseError
          }

          // Up here rather than in ACTIVITY, which is where the rule writes
          // are made but which hides itself when the log is empty. A refused
          // write has to be visible from wherever it was made.
          NoticeText {
            visible: controld.ruleError !== ""
            text: controld.ruleError
          }

          NoticeText {
            visible: controld.lastHint !== "" && !root.showEmptyState
            text: controld.lastHint
            color: root.dim
          }

          EmptyState {
            visible: controld.checkedInstall && !controld.installed
            title: "Install the Control D CLI"
            message: "This panel reads your account through cdctl. Install it, then sign in."
          }

          EmptyState {
            visible: controld.installed && controld.needsAuth
            title: "Sign in to Control D"
            message: "Run cdctl auth login --token-stdin with a token from the Control D dashboard, then reopen this panel."
          }

          // Paused on purpose looks identical to never set up, so this state
          // exists to tell them apart. No button: the action is the switch in
          // the hero.
          EmptyState {
            visible: root.unprotected && controld.canPause
            title: "Control D is paused"
            message: "This machine is resolving DNS without it, so there is nothing to report until it is back on. Use the switch above."
            actionText: ""
          }

          EmptyState {
            visible: root.unprotected && !controld.canPause
            title: "No Control D resolver on this machine"
            message: "Nothing in this host's DNS config points at Control D, so there is no endpoint to report on. A router or network that filters upstream would not show up here either."
            actionText: "Open setup guide"
            actionUrl: root.guideUrl
          }

          // The two causes need different things from the reader, so the panel
          // names which one it hit.
          EmptyState {
            visible: root.endpointUnknown
            title: "This machine could not be identified"
            message: controld.devicesError !== ""
              ? "Its DNS goes through Control D, but reading your endpoints failed, so the panel cannot tell which one this is."
              : "Its DNS goes through Control D, but that endpoint is not in this account. Check you are signed in to the account that owns it."
            detail: controld.devicesError
            actionText: "Open dashboard"
            actionUrl: root.dashboardUrl
          }

          // The built-in panels' key/value idiom: attributes sit under the
          // hero without a header of their own.
          Column {
            id: machineSection
            visible: root.showEndpoint
            width: parent.width
            spacing: Style.spacing.labelGap

            FactGrid {
              width: parent.width

              // No Profile row: the hero's subtitle is that. The id is the
              // whole endpoint -- every resolver address is that id plus a
              // constant suffix, and Protocol says which form it takes.
              InfoLabel { text: "Endpoint" }
              DetailValue {
                text: controld.endpoint ? controld.endpoint.id : "--"
                copyable: controld.endpoint !== null
                tooltipText: "Copy endpoint ID"
              }
              InfoLabel { text: "Protocol" }
              DetailValue { text: controld.endpointTransport !== "" ? controld.endpointTransport : "--" }

              // Probed on this machine rather than taken from the account's
              // record of the device. A probe that names no manager says so,
              // and offers to have the setup reported.
              InfoLabel { text: "Resolver" }
              DetailValue {
                text: controld.resolverLine
                linkUrl: controld.resolverUnknown ? root.issuesUrl : ""
                tooltipText: "Resolver not recognised. Report your setup on GitHub so it can be added."
              }
              // What happens to a domain that matches no rule, filter or
              // service.
              InfoLabel { text: "Unmatched" }
              DetailValue { text: controld.activeProfile ? Model.actionLabel(controld.activeProfile.defaultAction) : "--" }
            }
          }

          // Only while picking: a list of what could be enforced is noise next
          // to the hero, which names what is.
          Column {
            id: profilePicker
            visible: root.profilePickerOpen
            width: parent.width
            spacing: Style.spacing.labelGap

            Repeater {
              model: root.profilePickerOpen ? controld.profiles : []

              // CursorSurface paints where the cursor is and what is in force
              // differently, and never reads the mouse: hover moves the
              // panel's cursor and the row draws from that, so there is one
              // highlight on screen however you are driving it.
              CursorSurface {
                id: profileRow
                required property var modelData
                required property int index
                readonly property string cursorKey: "profileOption:" + index
                readonly property bool enforced: modelData.id === controld.enforcedProfileId
                readonly property bool switching: enforced && controld.enforceBusy

                width: profilePicker.width
                implicitHeight: profileLabel.implicitHeight + Style.space(10)
                hasCursor: root.cursorActive && root.cursorKey === cursorKey
                current: enforced
                foreground: root.foreground
                accent: Color.accent
                fill: root.hoverFill
                currentFill: root.selectedFill

                Text {
                  textFormat: Text.PlainText
                  id: profileLabel
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(8)
                  // Bounded by whatever is to its right, so a profile named at
                  // length is cut rather than drawn through the panel edge.
                  anchors.right: profileStatus.visible ? profileStatus.left : parent.right
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  elide: Text.ElideRight
                  text: profileRow.modelData.name
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: profileRow.enforced
                }

                CaptionText {
                  id: profileStatus
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  visible: profileRow.enforced
                  text: profileRow.switching ? "switching..." : "in force"
                }

                RowMouseArea {
                  cursorKey: profileRow.cursorKey
                  enabled: !controld.enforceBusy
                  onClicked: {
                    controld.setEnforcedProfile(profileRow.modelData.id)
                    root.closeProfilePicker()
                  }
                }
              }
            }
          }

          NoticeText {
            visible: controld.enforceError !== ""
            text: controld.enforceError
          }

          PanelSeparator {
            visible: root.showStats
            foreground: root.foreground
          }

          Column {
            id: statsSection
            visible: root.showStats
            width: parent.width
            spacing: Style.space(10)

            // The window governs everything in this section, so it sits with
            // the section's own title.
            SectionHeader {
              text: "STATISTICS"

              ChipGroup {
                options: Model.windowOptions()
                value: String(controld.statsHours)
                onChanged: function(v) { controld.setStatsWindow(v) }
              }
            }

            CaptionText {
              width: parent.width
              visible: root.statsCaption !== ""
              text: root.statsCaption
            }

            Sparkline {
              width: parent.width
              visible: controld.stats !== null && controld.stats.series.length > 1
              series: controld.stats ? controld.stats.series : []
            }

            FactGrid {
              width: parent.width
              visible: controld.stats !== null

              InfoLabel { text: "Queries" }
              DetailValue { text: controld.stats ? Model.formatCount(controld.stats.totals.all) : "--" }
              InfoLabel { text: "Blocked" }
              DetailValue {
                text: {
                  if (!controld.stats) return "--"
                  var share = Model.blockedShare(controld.stats.totals.all, controld.stats.totals.blocked)
                  var count = Model.formatCount(controld.stats.totals.blocked)
                  return share !== "" ? count + " (" + share + ")" : count
                }
              }
            }

            CaptionText {
              width: parent.width
              visible: controld.statsError !== ""
              text: controld.statsError
              wrapMode: Text.WordWrap
            }

            // The verdict governs the two lists directly beneath it, so it
            // sits tight against them rather than floating under the chart.
            Column {
              width: parent.width
              visible: controld.stats !== null
              spacing: Style.space(10)
              topPadding: Style.space(4)

              SectionHeader {
                text: "BREAKDOWN"

                ChipGroup {
                  options: Model.actionOptions()
                  value: String(controld.statsAction)
                  onChanged: function(v) { controld.setStatsAction(v) }
                }
              }

              CaptionText {
                width: parent.width
                visible: root.actionRows.length === 0 && controld.statsError === ""
                text: "Nothing " + root.actionWord + " in this window."
              }

              MeterList {
                id: domainList
                width: parent.width
                title: "DOMAINS"
                rows: root.actionRows
                // A hostname is the one value here that goes straight into
                // `cdctl rule create`, a browser, or a dig.
                copyable: true
                cursorPrefix: "domain:"
              }

              MeterList {
                id: filterList
                width: parent.width
                title: "FILTERS"
                rows: controld.stats ? controld.stats.filters : []
                pretty: true
                cursorPrefix: "filter:"
              }
            }

            Column {
              width: parent.width
              visible: root.destinationRows.length > 0
              spacing: Style.space(6)

              SectionHeader {
                text: "DESTINATIONS"

                ChipGroup {
                  options: [{ value: "networks", label: "Networks" }, { value: "countries", label: "Countries" }]
                  value: root.destinationView
                  onChanged: function(v) { root.destinationView = v }
                }
              }

              MeterList {
                id: destinationList
                width: parent.width
                rows: root.destinationRows
                cursorPrefix: "destination:"
                // Codes name nothing on their own, so the row spells them out.
                labelFor: root.destinationView === "countries" ? "country" : ""
              }
            }
          }

          PanelSeparator {
            visible: root.showActivity
            foreground: root.foreground
          }

          Column {
            id: activitySection
            visible: root.showActivity
            width: parent.width
            spacing: Style.space(8)

            // The verdict governs the whole log, so it sits with the section's
            // own title, as the window does for statistics.
            SectionHeader {
              text: "ACTIVITY"

              ChipGroup {
                options: Model.activityFilterOptions()
                value: controld.activityFilter
                onChanged: function(v) { controld.setActivityFilter(v) }
              }
            }

            // A line of its own: the verdict chips already fill the title row,
            // and squeezing the switch in there would push the last chip off
            // the panel.
            RowLayout {
              width: parent.width
              spacing: Style.space(8)

              Item { Layout.fillWidth: true }

              CaptionText {
                Layout.alignment: Qt.AlignVCenter
                text: "Grouped"
              }

              ToggleSwitch {
                id: groupSwitch
                Layout.alignment: Qt.AlignVCenter
                checked: controld.activityGrouped
                foreground: root.foreground
                onToggled: controld.setActivityGrouped(!controld.activityGrouped)

                PanelToolTip {
                  visible: groupSwitch.containsMouse
                  text: "One row per host, with a repeat count"
                  fontFamily: root.fontFamily
                }
              }
            }

            CaptionText {
              width: parent.width
              visible: text !== ""
              text: {
                if (controld.activityError !== "") return controld.activityError
                return controld.activityLog.length === 0 ? root.emptyActivityLine : ""
              }
              color: controld.activityError !== "" ? root.urgent : root.dim
              wrapMode: Text.WordWrap
            }

            Column {
              id: activityColumn
              width: parent.width
              spacing: Style.space(6)

              // New lookups arrive at the top on every repoll, so every row
              // below shifts down under whatever the pointer was aiming at.
              // These rows write account rules, so that is not a flicker, it is
              // a rule against the wrong host. The list holds still while the
              // pointer is in it, and takes the newer page once it leaves.
              HoverHandler { id: activityHover }

              Repeater {
                model: root.visibleActivity
                ActivityRow {
                  required property var modelData
                  required property int index
                  width: parent.width
                  query: modelData
                  cursorKey: "activity:" + index
                }
              }

              MoreRow {
                width: parent.width
                visible: root.activityExpandable
                cursorKey: "activity:more"
                text: root.activityExpanded ? "Show less" : "+" + root.hiddenActivity
                onActivated: root.toggleActivityExpanded(this)
              }
            }
          }

          PanelSeparator {
            visible: root.showRules
            foreground: root.foreground
          }

          Column {
            id: rulesSection
            visible: root.showRules
            width: parent.width
            spacing: Style.space(10)

            // The machine facts above already name the profile these rules
            // belong to.
            SectionHeader {
              text: "RULES"

              CaptionText {
                Layout.alignment: Qt.AlignVCenter
                Layout.maximumWidth: parent.width * 0.6
                visible: root.rulesCaption !== ""
                text: root.rulesCaption
                elide: Text.ElideRight
              }

              // A word in a bordered box, as every other control at the right
              // of a section header here is: a bare glyph reads as a row
              // control that drifted up. It renames itself rather than leave
              // two buttons reading "Add" on one screen.
              ChipButton {
                text: root.addRuleOpen ? "Cancel" : "Add"
                Layout.alignment: Qt.AlignVCenter
                onClicked: root.toggleAddRule()
              }
            }

            // Opens under its own header, as the profile list does under the
            // hero and the delete question under its row.
            Column {
              id: addRuleForm
              visible: root.addRuleOpen
              width: parent.width
              spacing: Style.space(8)
              topPadding: Style.space(2)

              TextField {
                id: addRuleHost
                width: parent.width
                placeholderText: "hostname, or *.example.com"
                foreground: root.foreground
                accent: Color.accent
                onAccepted: root.submitAddRule()
              }

              RowLayout {
                width: parent.width
                spacing: Style.space(8)

                ChipGroup {
                  options: [{ value: "block", label: "Block" }, { value: "bypass", label: "Bypass" }]
                  value: root.addRuleAction
                  onChanged: function(v) { root.addRuleAction = v }
                }

                Item { Layout.fillWidth: true }

                ChipButton {
                  text: "Add"
                  enabled: Model.validHostname(addRuleHost.text) && !controld.ruleBusy
                  onClicked: root.submitAddRule()
                }
              }
            }

            Column {
              id: ruleColumn
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: controld.visibleRuleRows
                Item {
                  id: rowSlot
                  required property var modelData
                  required property int index
                  readonly property bool isRuleRow: modelData.kind === "rule"
                  width: ruleColumn.width
                  implicitHeight: isRuleRow ? ruleItem.implicitHeight : folderItem.implicitHeight

                  FolderRow {
                    id: folderItem
                    visible: !rowSlot.isRuleRow
                    width: parent.width
                    group: rowSlot.modelData.group
                  }

                  RuleRow {
                    id: ruleItem
                    visible: rowSlot.isRuleRow
                    width: parent.width
                    rule: rowSlot.isRuleRow ? rowSlot.modelData.rule : null
                    rowIndex: rowSlot.isRuleRow ? root.ruleOrdinal(rowSlot.index) : -1
                  }
                }
              }
            }
          }
        }
      }

      // Keys are invisible by nature, so ? reveals them rather than a legend
      // sitting there uninvited.
      Column {
        id: legend
        visible: root.legendOpen
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        spacing: Style.space(6)

        PanelSeparator { foreground: root.foreground }

        GridLayout {
          width: parent.width
          columns: 3
          columnSpacing: Style.space(12)
          rowSpacing: Style.space(3)

          Repeater {
            model: root.legendKeys

            Row {
              required property var modelData
              spacing: Style.space(6)
              // Equal thirds, so the keys line up as columns rather than
              // drifting with the length of each description.
              Layout.fillWidth: true
              Layout.preferredWidth: 1

              CaptionText {
                width: Style.space(30)
                horizontalAlignment: Text.AlignRight
                text: modelData.key
                color: Qt.darker(root.foreground, 1.25)
              }

              CaptionText { text: modelData.what }
            }
          }
        }
      }
    }
  }

  // Position of a rule among rule rows only, given its index in the drawn list.
  function ruleOrdinal(rowsIndex) {
    var rows = controld.visibleRuleRows
    var n = 0
    for (var i = 0; i < rowsIndex && i < rows.length; i++) if (rows[i].kind === "rule") n++
    return n
  }

  // Panel-wide text defaults, so each use says only what makes it different.
  // Hostnames, filter names and error messages arrive from the network, and
  // `Text.AutoText` reads anything tag-shaped as rich text: an `<img>` in a
  // looked-up name would fetch from the shell process, and rich text ignores
  // `elide`. Every component that shows a value states the format instead.
  component CaptionText: Text {
    color: root.dim
    textFormat: Text.PlainText
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  component BodyText: Text {
    color: root.foreground
    textFormat: Text.PlainText
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
  }

  // A line across the panel: a failure, or the hint that follows one.
  component NoticeText: Text {
    width: parent.width
    color: root.urgent
    textFormat: Text.PlainText
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.WordWrap
  }

  // A section title, with whatever governs the section at the right of it. No
  // icon: the built-in panels label their sections with text alone.
  component SectionHeader: RowLayout {
    id: sectionHeader
    property string text: ""

    width: parent.width
    spacing: Style.space(8)

    PanelSectionHeader {
      text: sectionHeader.text
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    Item { Layout.fillWidth: true }
  }

  component ChipGroup: ButtonGroup {
    foreground: root.foreground
    accent: Color.accent
    fontFamily: root.fontFamily
    fontSize: Style.font.caption
  }

  component ChipButton: Button {
    bordered: true
    foreground: root.foreground
    accent: Color.accent
    fontFamily: root.fontFamily
    fontSize: Style.font.caption
  }

  // Fills the row it is declared in: pointing at a row selects it, and the
  // gate is what stops a row that slid under a stationary pointer from taking
  // the cursor back.
  component RowMouseArea: MouseArea {
    id: rowArea
    property string cursorKey: ""

    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onEntered: if (rowArea.cursorKey !== "")
      root.setCursorFromPointer(rowArea.cursorKey, rowArea.parent, { x: rowArea.mouseX, y: rowArea.mouseY })
    onPositionChanged: function(mouse) {
      if (rowArea.cursorKey !== "") root.setCursorFromPointer(rowArea.cursorKey, rowArea.parent, mouse)
    }
  }

  // The glyph at the head of an activity or rule row, and the click that acts
  // on it.
  component RowGlyph: Item {
    id: rowGlyph
    property string glyph: ""
    property color glyphColor: root.foreground
    property real glyphOpacity: 1.0
    property bool actionable: true
    // The glyph's own hover, not the row's: crossing a row on the way
    // somewhere else should not flicker every glyph it passes, and a control
    // reading the row's hover would put itself away as the pointer arrived.
    property bool reached: false
    property string tooltipText: ""
    signal hovered(bool on)
    signal clicked()

    // A fixed cell, not the glyph's own width: these glyphs do not all advance
    // the same, so sizing to the one on show would slide the hostname sideways
    // whenever the pointer changes it.
    Layout.preferredWidth: Style.space(22)
    Layout.preferredHeight: glyphText.implicitHeight
    Layout.alignment: Qt.AlignVCenter

    Text {
      textFormat: Text.PlainText
      id: glyphText
      anchors.centerIn: parent
      text: rowGlyph.glyph
      color: rowGlyph.glyphColor
      opacity: rowGlyph.glyphOpacity
      font.family: root.fontFamily
      font.pixelSize: Style.font.icon
    }

    MouseArea {
      anchors.fill: parent
      // Left enabled while a write is in flight: taking the mouse area away
      // under the pointer drops its hover, and giving it back does not restore
      // it until the pointer moves, so the row just acted on would drop to its
      // resting glyph. The write turns a second click away on its own.
      enabled: rowGlyph.actionable
      hoverEnabled: enabled
      cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onEntered: rowGlyph.hovered(true)
      onExited: rowGlyph.hovered(false)
      onClicked: rowGlyph.clicked()
    }

    PanelToolTip {
      visible: rowGlyph.reached
      text: rowGlyph.tooltipText
      fontFamily: root.fontFamily
    }
  }

  component FolderRow: Item {
    id: folderRow
    property var group: null
    readonly property int ruleTotal: group ? group.rules.length : 0

    implicitHeight: folderInner.implicitHeight + Style.space(6)

    RowLayout {
      id: folderInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      CaptionText {
        text: "󰉋"
        Layout.preferredWidth: Style.space(22)
        Layout.alignment: Qt.AlignVCenter
        horizontalAlignment: Text.AlignHCenter
      }

      CaptionText {
        Layout.fillWidth: true
        Layout.alignment: Qt.AlignVCenter
        text: {
          var name = folderRow.group ? folderRow.group.name.toUpperCase() : ""
          var suffix = folderRow.ruleTotal + (folderRow.ruleTotal === 1 ? " RULE" : " RULES")
          if (folderRow.group && folderRow.group.folder && !folderRow.group.folder.enabled) suffix += " · DISABLED"
          return name + "  ·  " + suffix
        }
        font.bold: true
        elide: Text.ElideRight
      }
    }
  }

  // One geometry for every key/value block, so a label in one lines up with
  // the label in the next.
  component FactGrid: GridLayout {
    columns: 4
    columnSpacing: Style.space(12)
    rowSpacing: Style.spacing.labelGap
  }

  component InfoLabel: Text {
    color: root.foreground
    opacity: 0.6
    textFormat: Text.PlainText
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    Layout.fillWidth: true
    Layout.preferredWidth: 3
  }

  component DetailValue: Text {
    id: detailValue
    color: root.foreground
    textFormat: Text.PlainText
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    // Deliberately not elided. Every value here comes from a closed set -- an
    // endpoint id, a protocol name, a resolver, an action -- and letting the
    // text keep its own width is what makes the grid lend the long ones room
    // from the labels. `systemd-resolved` fits only by that lending.
    property bool copyable: false
    // Set instead of `copyable` when the value is worth acting on rather than
    // taking: the glyph and the click follow.
    property string linkUrl: ""
    property string tooltipText: "Copy to clipboard"
    readonly property bool actionable: (copyable || linkUrl !== "") && text !== ""

    Layout.fillWidth: true
    Layout.preferredWidth: 4
    horizontalAlignment: Text.AlignRight
    // Reserve the glyph's width whether or not it is showing, so the value
    // does not shift sideways under the pointer.
    rightPadding: actionable ? copyGlyph.width + Style.space(4) : 0

    CaptionText {
      id: copyGlyph
      visible: detailValue.actionable
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: detailValue.linkUrl !== "" ? "󰏌" : "󰆏"
      color: detailValue.color
      opacity: valueMouse.containsMouse ? 1.0 : 0.45

      Behavior on opacity {
        NumberAnimation { duration: 120; easing.type: Easing.OutQuad }
      }
    }

    MouseArea {
      id: valueMouse
      anchors.fill: parent
      enabled: detailValue.actionable
      hoverEnabled: enabled
      cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: {
        if (detailValue.linkUrl !== "") Quickshell.execDetached(["omarchy-launch-browser", detailValue.linkUrl])
        else controld.copyToClipboard(detailValue.text)
      }
    }

    PanelToolTip {
      visible: valueMouse.enabled && valueMouse.containsMouse
      text: detailValue.tooltipText
      fontFamily: root.fontFamily
    }
  }

  // Queries over the window: the line is every query, the shaded area under
  // it is the blocked share, so the gap between them is what was let through.
  component Sparkline: Item {
    id: spark
    property var series: []
    readonly property real peak: {
      var items = spark.series || []
      var max = 0
      for (var i = 0; i < items.length; i++) max = Math.max(max, items[i].total)
      return max
    }

    function pointsFor(key, closed) {
      var items = spark.series || []
      if (items.length < 2 || spark.peak <= 0) return []
      var out = closed === true ? [Qt.point(0, spark.height)] : []
      for (var i = 0; i < items.length; i++) {
        out.push(Qt.point((i / (items.length - 1)) * spark.width,
                          (1 - items[i][key] / spark.peak) * spark.height))
      }
      if (closed === true) out.push(Qt.point(spark.width, spark.height))
      return out
    }

    implicitHeight: Style.space(44)

    Shape {
      anchors.fill: parent
      antialiasing: true
      layer.enabled: true
      layer.samples: 4
      preferredRendererType: Shape.CurveRenderer

      ShapePath {
        strokeWidth: 0
        strokeColor: "transparent"
        fillColor: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.18)
        PathPolyline { path: spark.pointsFor("blocked", true) }
      }

      ShapePath {
        strokeWidth: Math.max(1, Style.space(2))
        strokeColor: Qt.darker(root.foreground, 1.3)
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        PathPolyline { path: spark.pointsFor("total", false) }
      }
    }
  }

  // A titled list of rows filled in proportion to the biggest row, so the bar
  // is the row rather than a rule beneath it.
  component MeterList: Column {
    id: meterList
    property string title: ""
    property var rows: []
    // Filter ids arrive as slugs and country codes as two letters; both read
    // badly raw.
    property bool pretty: false
    property string labelFor: ""
    // Only rows whose value can be acted on elsewhere offer to be copied.
    property bool copyable: false
    // Set for a list the cursor walks; rows key off it by index.
    property string cursorPrefix: ""

    visible: rows.length > 0
    spacing: Style.space(1)

    // A level below the block headers above it: same shape, less weight.
    CaptionText {
      text: meterList.title
      visible: meterList.title !== ""
      bottomPadding: Style.space(4)
      topPadding: Math.ceil(Style.font.caption * 0.15)
    }

    Repeater {
      model: meterList.rows
      MeterRow {
        required property var modelData
        required property int index
        width: meterList.width
        cursorKey: meterList.cursorPrefix === "" ? "" : meterList.cursorPrefix + index
        label: {
          if (meterList.pretty) return Model.filterLabel(modelData.value)
          if (meterList.labelFor === "country") return Model.countryName(modelData.value)
          return modelData.value
        }
        copyValue: meterList.copyable ? modelData.value : ""
        hits: modelData.count
        ratio: Model.meterRatio(modelData.count, meterList.rows)
      }
    }
  }

  // Label, bar, value on one line, as the agents panel lays out its tokens by
  // day.
  component MeterRow: Item {
    id: meterRow
    property string label: ""
    property string copyValue: ""
    property string cursorKey: ""
    property int hits: 0
    property real ratio: 0

    implicitHeight: rowLabel.implicitHeight + Style.spacing.sm * 2

    readonly property bool interactive: copyValue !== ""
    readonly property bool hasCursor: cursorKey !== "" && root.cursorActive && root.cursorKey === cursorKey
    // The cursor marks where you are reading, so it shows on every row it can
    // reach. Hover still lights up only what can be acted on.
    readonly property bool hot: hasCursor || (interactive && rowMouse.containsMouse)

    BodyText {
      id: rowLabel
      anchors.left: parent.left
      anchors.right: meterTrack.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      text: meterRow.label
      color: meterRow.hot ? root.foreground : Qt.darker(root.foreground, 1.25)
      elide: Text.ElideMiddle
    }

    Rectangle {
      id: meterTrack
      anchors.right: rowValue.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      // The label carries the identity, so the bar takes only what it needs
      // to stay readable as a comparison.
      width: parent.width * 0.22
      height: Math.max(Style.space(3), Math.round(Style.spacing.controlHeight * 0.10))
      radius: height / 2
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.10)

      Rectangle {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        height: parent.height
        radius: parent.radius
        width: parent.width * Math.max(0, Math.min(1, meterRow.ratio))
        color: meterRow.hot ? root.foreground : Qt.darker(root.foreground, 1.2)

        Behavior on width {
          NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }
      }
    }

    BodyText {
      id: rowValue
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(38)
      horizontalAlignment: Text.AlignRight
      text: Model.formatCount(meterRow.hits)
      color: root.dim
    }

    RowMouseArea {
      id: rowMouse
      cursorKey: meterRow.cursorKey
      cursorShape: meterRow.interactive ? Qt.PointingHandCursor : Qt.ArrowCursor
      acceptedButtons: meterRow.interactive ? Qt.LeftButton : Qt.NoButton
      onClicked: controld.copyToClipboard(meterRow.copyValue)
    }

    PanelToolTip {
      visible: meterRow.interactive && rowMouse.containsMouse
      text: "Copy " + meterRow.copyValue
      fontFamily: root.fontFamily
    }
  }

  // A dead end with a way out: what is missing, what to do, and a link to
  // the guide for anything longer than one line.
  component EmptyState: Column {
    id: emptyState
    property string title: ""
    property string message: ""
    // What went wrong underneath, when there is something to quote.
    property string detail: ""
    property string actionText: "Open setup guide"
    property string actionUrl: root.guideUrl

    width: parent.width
    spacing: Style.space(6)

    Text {
      textFormat: Text.PlainText
      width: emptyState.width
      text: emptyState.title
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.subtitle
      wrapMode: Text.WordWrap
    }

    BodyText {
      width: emptyState.width
      text: emptyState.message
      color: root.dim
      wrapMode: Text.WordWrap
    }

    NoticeText {
      visible: emptyState.detail !== ""
      text: emptyState.detail
    }

    Row {
      // A state that deliberately offers no action offers no agent either:
      // being paused on purpose is not a thing to go debugging.
      visible: emptyState.actionText !== ""
      spacing: Style.space(8)
      topPadding: Style.space(4)

      ChipButton {
        text: emptyState.actionText
        fontSize: Style.font.body
        onClicked: Quickshell.execDetached(["omarchy-launch-browser", emptyState.actionUrl])
      }

      // Offered here rather than everywhere: a panel that is working has
      // nothing to ask about, and this is where somebody stuck already is.
      ChipButton {
        text: "Ask an agent"
        fontSize: Style.font.body
        onClicked: root.askAgent()
      }
    }
  }

  // The foot of a list that draws short. Reads as a control rather than a row,
  // being the one thing there that acts on the list instead of belonging to it.
  component MoreRow: Item {
    id: moreRow
    property string text: ""
    property string cursorKey: ""
    signal activated()
    readonly property bool hasCursor: cursorKey !== "" && root.cursorActive && root.cursorKey === cursorKey
    readonly property bool hot: moreMouse.containsMouse || hasCursor

    implicitHeight: moreLabel.implicitHeight + Style.spacing.sm * 2

    CaptionText {
      id: moreLabel
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: moreRow.text
      color: moreRow.hot ? root.foreground : root.dim

      Behavior on color {
        ColorAnimation { duration: 120; easing.type: Easing.OutQuad }
      }
    }

    RowMouseArea {
      id: moreMouse
      cursorKey: moreRow.cursorKey
      onClicked: moreRow.activated()
    }
  }

  // One lookup: what was asked, what happened to it, and when. Rows for the
  // same host and verdict arrive already folded, carrying a tally.
  component ActivityRow: Item {
    id: activityRow
    property var query: null
    property string cursorKey: ""
    readonly property string question: query ? query.question : ""
    readonly property bool blocked: query && query.action === 0
    readonly property bool hasCursor: cursorKey !== "" && root.cursorActive && root.cursorKey === cursorKey
    readonly property bool glyphReached: question !== "" && root.hoveredGlyphHost === question
    readonly property bool hot: activityMouse.containsMouse || glyphReached || hasCursor
    // The override this row offers, given what the profile already says.
    readonly property var intent: Model.ruleIntent(query, controld.rules)
    readonly property bool actionable: intent.verb !== "" && controld.activeProfile !== null
    readonly property bool applied: intent.verb === "delete"
    readonly property string verdictName: Model.actionName(query ? query.action : -1)
    // The rule contradicts what this lookup recorded, so the record is spent:
    // struck through for the moment it is held, then gone. A row the rule
    // agrees with is not spent -- the rule is why it reads as it does.
    readonly property bool superseded: applied && intent.action !== verdictName
    readonly property bool pending: controld.ruleBusy && controld.pendingRuleHost === question

    // Where the host stands: the override if this profile holds one, else what
    // the log recorded.
    readonly property string restingGlyph: Model.actionGlyph(applied ? intent.action : verdictName)
    // What the click will do. A row with no rule shows the verdict the click
    // writes -- exact, since the rule is what decides it -- and a row with one
    // shows undo, which is all the click promises. So the glyph answers "what
    // is it" until you reach for it, then "what will this do".
    readonly property string reachedGlyph: applied ? Model.UNDO_GLYPH : Model.actionGlyph(intent.action)
    // Accent only at rest, where it is the one thing telling your rule from an
    // ordinary bypass. Under the pointer the glyph has already changed shape,
    // and saying it twice just makes it louder.
    property color verdictColor: {
      if (glyphReached && actionable) return root.foreground
      if (applied) return Color.accent
      return blocked ? root.foreground : root.dim
    }

    Behavior on verdictColor { ColorAnimation { duration: 60 } }

    implicitHeight: activityText.implicitHeight + Style.spacing.sm * 2

    // Declared before the row's contents and therefore beneath them, so the
    // glyph takes its own clicks and everything else falls through to the row.
    // Filling the row over the top would swallow the glyph.
    RowMouseArea {
      id: activityMouse
      cursorKey: activityRow.cursorKey
      onClicked: controld.copyToClipboard(activityRow.question)
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)

      RowGlyph {
        glyph: activityRow.actionable && activityRow.glyphReached
          ? activityRow.reachedGlyph : activityRow.restingGlyph
        glyphColor: activityRow.verdictColor
        glyphOpacity: activityRow.pending ? 0.4 : 1.0
        actionable: activityRow.actionable
        reached: activityRow.glyphReached
        tooltipText: activityRow.applied
          ? ("Remove this " + activityRow.intent.action + " rule")
          : (activityRow.intent.action + " this host")
        onHovered: function(on) {
          if (on) root.hoveredGlyphHost = activityRow.question
          else if (root.hoveredGlyphHost === activityRow.question) root.hoveredGlyphHost = ""
        }
        onClicked: controld.applyRuleIntent(activityRow.intent)
      }

      ColumnLayout {
        id: activityText
        Layout.fillWidth: true
        spacing: Style.space(1)

        BodyText {
          Layout.fillWidth: true
          text: activityRow.question
          color: activityRow.hot ? root.foreground : Qt.darker(root.foreground, 1.25)
          // Struck through, not dimmed: dimming reads as "less important",
          // which a row you just acted on is not. A line through it says the
          // verdict it records no longer stands.
          font.strikeout: activityRow.superseded
          elide: Text.ElideMiddle
        }

        CaptionText {
          Layout.fillWidth: true
          text: Model.activityDetail(activityRow.query)
          elide: Text.ElideRight
        }
      }

      CaptionText {
        text: Model.clockTime(activityRow.query ? activityRow.query.time : "")
        Layout.alignment: Qt.AlignVCenter
      }
    }

    PanelToolTip {
      visible: activityMouse.containsMouse
      text: "Copy " + activityRow.question
      fontFamily: root.fontFamily
    }
  }

  component RuleRow: CursorSurface {
    id: ruleRow
    property var rule: null
    property int rowIndex: 0
    readonly property bool ruleEnabled: rule ? rule.enabled : false
    readonly property string hostname: rule ? rule.hostname : ""
    readonly property bool glyphReached: hostname !== "" && root.hoveredRuleHost === hostname
    readonly property bool pending: controld.ruleBusy && controld.pendingRuleHost === hostname
    // Reported by the delete button itself: the row's own hover goes out from
    // under it the moment the pointer arrives on the button.
    property bool ruleDeleteHovered: false
    readonly property bool confirming: hostname !== "" && root.pendingDeleteHost === hostname
    // The row grows downwards, so on the last rule the question opens below
    // the fold. Asking a question nobody can see is worse than not asking --
    // and it has to wait for the height, since scrolling on the change itself
    // reveals the row at the size it was before the strip was in it.
    onHeightChanged: if (confirming) root.scrollItemIntoView(ruleRow)

    hasCursor: root.cursorActive && root.cursorKey === "rule:" + rowIndex
    foreground: root.foreground
    fill: root.hoverFill

    implicitHeight: ruleContent.implicitHeight + Style.spacing.rowPaddingX
      + (confirming ? confirmStrip.implicitHeight + Style.space(8) : 0)

    RowMouseArea {
      id: ruleMouse
      cursorKey: "rule:" + ruleRow.rowIndex
      onClicked: if (ruleRow.rule) controld.copyToClipboard(ruleRow.rule.hostname)
    }

    RowLayout {
      id: ruleTop
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.topMargin: Style.spacing.rowPaddingX / 2
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(8)

      // At rest the glyph says what the rule does; reaching for it says what
      // the click does, which is not the same question -- toggling leaves the
      // action alone. Pause on a rule that is running, play on one that is
      // not, so the glyph says which way the click goes.
      RowGlyph {
        glyph: ruleRow.glyphReached
          ? (ruleRow.ruleEnabled ? Model.PAUSE_GLYPH : Model.PLAY_GLYPH)
          : Model.actionGlyph(ruleRow.rule ? ruleRow.rule.action : "")
        glyphColor: ruleRow.ruleEnabled || ruleRow.glyphReached ? root.foreground : root.dim
        glyphOpacity: ruleRow.pending ? 0.4 : (ruleRow.ruleEnabled || ruleRow.glyphReached ? 1.0 : 0.6)
        reached: ruleRow.glyphReached
        tooltipText: ruleRow.ruleEnabled ? "Pause this rule" : "Resume this rule"
        onHovered: function(on) {
          if (on) root.hoveredRuleHost = ruleRow.hostname
          else if (root.hoveredRuleHost === ruleRow.hostname) root.hoveredRuleHost = ""
        }
        onClicked: controld.toggleRule(ruleRow.rule)
      }

      ColumnLayout {
        id: ruleContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        BodyText {
          Layout.fillWidth: true
          text: ruleRow.hostname
          color: ruleRow.ruleEnabled ? root.foreground : root.dim
          elide: Text.ElideRight
          // The same line the activity log draws through a verdict a rule has
          // overruled. A rule switched off is the same claim about itself.
          font.strikeout: !ruleRow.ruleEnabled
        }

        CaptionText {
          Layout.fillWidth: true
          text: Model.ruleDetail(ruleRow.rule)
          elide: Text.ElideRight
        }
      }

      // Always drawn, never revealed on hover: a control that appears under
      // the pointer is a control that can move out from under it. Quiet until
      // reached, and no louder there -- the confirmation is what guards this,
      // and a red icon on every row makes the list look alarming at rest.
      PanelActionButton {
        iconText: Model.TRASH_GLYPH
        // Silenced while the confirmation is up: the pointer is still on this
        // button, and its tooltip would sit over the answer it is asking for.
        tooltipText: ruleRow.confirming ? "" : "Delete this rule"
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        opacity: ruleRow.hasCursor || ruleDeleteHovered ? 1.0 : 0.35
        Layout.alignment: Qt.AlignVCenter
        onHovered: function(on) { ruleRow.ruleDeleteHovered = on }
        onClicked: root.askDeleteRule(ruleRow.rule)
      }
    }

    // Under the row rather than over the panel: the rule being deleted stays
    // legible directly above the question that names it.
    RowLayout {
      id: confirmStrip
      visible: ruleRow.confirming
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: ruleTop.bottom
      anchors.topMargin: Style.space(8)
      anchors.leftMargin: Style.space(40)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(8)

      CaptionText {
        text: "Delete this rule?"
        color: root.foreground
        Layout.alignment: Qt.AlignVCenter
      }

      Item { Layout.fillWidth: true }

      ChipButton {
        text: "Keep"
        onClicked: root.pendingDeleteHost = ""
      }

      ChipButton {
        text: "Delete"
        foreground: root.urgent
        accent: root.urgent
        onClicked: root.confirmDeleteRule()
      }
    }

    PanelToolTip {
      visible: ruleMouse.containsMouse && !ruleRow.glyphReached && !ruleRow.confirming
      text: ruleRow.ruleEnabled ? "Copy hostname" : "Rule is off · copy hostname"
      fontFamily: root.fontFamily
    }
  }
}
