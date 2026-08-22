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

  // The cursor walks one flat list of actionable rows in document order, so
  // j/k does the same thing wherever it is. Rows that cannot be acted on are
  // not in it: the cursor visits exactly what hover already highlights.
  property string cursorKey: ""
  property bool cursorActive: false
  // Where the cursor was, so a row retired by a poll does not send it home.
  property int lastCursorIndex: 0

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  // What is chosen, as against where the cursor is. CursorSurface paints the
  // two differently on purpose: one highlight would say both at once.
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "transparent"

  // This panel describes one machine: the endpoint it resolves through and the
  // profile that endpoint enforces. Every section hangs off that, so without an
  // identified endpoint there is nothing to show and the panel says why.
  readonly property bool machineMode: controld.endpointState === "machine"
  readonly property bool showEndpoint: controld.ready && machineMode
  readonly property bool showRules: controld.ready && machineMode && controld.activeProfile !== null
  // No Control D resolver here at all, which is the only state that means this
  // machine is unprotected.
  readonly property bool unprotected: controld.ready && controld.endpointState === "none"
  // A Control D resolver we cannot put a name to: the device lookup failed, or
  // the endpoint belongs to another account. Protected, but not describable.
  readonly property bool endpointUnknown: controld.ready && controld.endpointState === "unknown"
  // Where to send someone who has neither the CLI nor an account set up.
  readonly property string guideUrl: "https://github.com/joaodrp/omarchy-controld-panel#readme"
  readonly property string dashboardUrl: "https://controld.com/dashboard"
  // Where an unrecognised setup goes, so the next person with it is covered.
  readonly property string issuesUrl: "https://github.com/joaodrp/omarchy-controld-panel/issues"
  // The panel is explaining itself rather than showing content.
  readonly property bool showEmptyState: (controld.checkedInstall && !controld.installed)
    || (controld.installed && controld.needsAuth)
    || unprotected || endpointUnknown
  readonly property bool showActivity: controld.ready && machineMode && controld.activityEnabled
    && (controld.activityLog.length > 0 || controld.activityError !== "")
  readonly property bool showStats: controld.ready && machineMode && controld.statsEnabled
    && (controld.statsAvailable || controld.statsError !== "")
  property bool legendOpen: false
  // The profile list, open under the hero. While it is open the cursor walks
  // its rows and nothing else: picking one is a write, so it should not be
  // possible to drift off it and press enter on something else.
  property bool profilePickerOpen: false
  // Which row's glyph the pointer is on, by host rather than by row. Writing a
  // rule rebuilds the list, and a rebuilt delegate's MouseArea reports no
  // hover -- the pointer never entered it, it was created underneath one. Held
  // here, the reach survives the rebuild it causes; held by index, it would
  // follow the position rather than the host.
  property string hoveredGlyphHost: ""
  // The same idea for the rules list, kept apart: a rule's hostname and an
  // activity row's question can be the same string, and reaching for one
  // should not light the other.
  property string hoveredRuleHost: ""
  // Only the keys that exist in the state being shown: a legend that lists
  // what does nothing here is worse than none.
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
      { key: "R", what: "refresh" }, { key: "esc", what: "close" })
    return keys
  }

  // The log is drawn short and expands in place. Rows past the fold are
  // already fetched, so this costs nothing but the space.
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
  // The window chips already name the range, so this says only what they
  // cannot.
  // Each chip says nothing happened in its own words, since "no queries yet"
  // is wrong on a tab that is simply the rare one.
  readonly property string emptyActivityLine: {
    if (controld.activityFilter === "bypassed") return "nothing bypassed in this window"
    if (controld.activityFilter === "others") return "no redirects or spoofs in this window"
    return "nothing blocked in this window"
  }
  readonly property string statsCaption: {
    if (!controld.statsAvailable) return "analytics off for this endpoint"
    if (controld.statsLoading) return "loading…"
    return ""
  }
  // Only rule rows take the cursor; folder headers are labels.
  // Set from the list's own hover rather than from any row, so crossing the
  // gap between two rows does not count as leaving.
  onActivityHoveredChanged: controld.activityHeld = activityHovered
  readonly property bool activityHovered: activityColumn && activityHover.hovered
  readonly property var cursorRules: cursorRuleList()
  readonly property bool headerHasCursor: cursorActive && cursorKey === "header" && controld.installed
  readonly property color iconColor: controld.ready && !unprotected ? foreground : dim
  readonly property color barIconColor: controld.ready && !unprotected ? barForeground : Qt.darker(barForeground, 1.55)
  // The hero names this machine's endpoint and what it enforces. With no
  // endpoint to name it carries the reason instead.
  readonly property string heroTitle: controld.endpoint ? controld.endpoint.name : "Control D"
  readonly property string heroMeta: {
    if (!controld.installed) return "cdctl is not installed"
    if (controld.needsAuth) return "Not authenticated"
    if (controld.refreshing && !controld.authenticated) return "Checking…"
    // The caret is the only thing saying the profile can be changed, since the
    // hero's meta is a plain string with nowhere to hang a control. The name is
    // the profile asked for rather than the one confirmed, so the hero answers
    // the click at once and the ellipsis carries the wait.
    if (controld.endpoint) {
      var name = controld.activeProfile ? controld.activeProfile.name : ""
      if (controld.enforceBusy) return name + "…"
      return name + (controld.canEnforce ? (profilePickerOpen ? " \udb80\udd43" : " \udb80\udd40") : "")
    }
    // With no endpoint to name, the empty state below carries the reason. The
    // hero says which account is signed in instead, which is what the reader
    // needs to act on it. The address alone: the region belongs to the
    // analytics host, answers nothing anyone asks here, and is what pushed
    // this line past the trailing controls into an ellipsis.
    return controld.email !== "" ? controld.email : controld.statusText
  }
  readonly property string rulesCaption: {
    if (controld.loadingRules && controld.rules.length === 0) return "Loading rules…"
    return Model.rulesCaption(controld.ruleCount, controld.shownRuleCount)
  }
  // The machine facts above already name the profile these rules belong to.
  readonly property string rulesTitle: "RULES"

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
      // Filters, networks and countries are read, not acted on: the cursor
      // still visits them so j/k walks the panel continuously, but they
      // carry no value, so yank passes over them.
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
    // Rows come and go as polls land: the activity log is rebuilt every
    // fifteen seconds and can change length, which retires a key like
    // "activity:7". Falling back to the first row would throw the cursor to
    // the top of the panel mid-read, so it lands on the nearest surviving
    // row instead.
    if (cursorItems.length === 0) { cursorKey = ""; return }
    if (cursorIndex >= 0) { lastCursorIndex = cursorIndex; return }
    cursorKey = cursorItems[Math.max(0, Math.min(cursorItems.length - 1, lastCursorIndex))].key
  }

  function moveCursor(dx, dy) {
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

  // What the row does when you press enter on it. Copy is the only action a
  // read-only panel has for most of them.
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

  // `b` and `B` act on the row under the cursor. The row already knows what
  // its override is, so the key only has to say which verdict it meant: asking
  // to bypass a host the log never blocked does nothing rather than writing a
  // rule the row was not offering.
  function applyRuleKey(action) {
    var entry = cursorActive ? currentCursor() : null
    if (!entry || entry.kind !== "activity") return
    var intent = Model.ruleIntent(visibleActivity[entry.index], controld.rules)
    if (intent.action !== action) return
    controld.applyRuleIntent(intent)
  }

  // Which rule the confirmation is about. Held rather than passed, because the
  // dialog outlives the row: the list can rebuild while it is open.
  property var pendingDeleteRule: null

  function askDeleteRule(rule) {
    if (!rule || controld.ruleBusy) return
    pendingDeleteRule = rule
  }

  // `x` switches the rule under the cursor off, or back on. Rules only: the
  // key names an operation that no other row has.
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

  // Collapsing the log takes rows out from above the row that did it, so
  // everything below slides up while the scroll offset stays put and the
  // reader lands in another section. Holding that row still is what makes the
  // list shrink under it rather than the panel move around it. Expanding needs
  // none of this: the new rows fill the space the row is pushed out of, which
  // is exactly what wanted seeing.
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

  // Section jumps: pin the section to the top of the view rather than
  // nudging it into sight, so the key lands somewhere predictable.
  function jumpTo(section) {
    if (!panelFlick || !section || !section.visible) return
    // Put the cursor on that section's first actionable row, so j/k carries
    // on from where the eye landed.
    var prefix = section === rulesSection ? "rule:"
      : section === statsSection ? "domain:"
      : section === activitySection ? "activity:"
      : section === machineSection ? "endpoint" : ""
    if (prefix !== "") {
      for (var i = 0; i < cursorItems.length; i++) {
        if (cursorItems[i].key === prefix || cursorItems[i].key.indexOf(prefix) === 0) {
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

  // The item under the cursor. Rows carry their own key rather than sitting
  // at a known index: a Repeater's delegates share their parent with the
  // Repeater itself and any header, so counting children lands on the wrong
  // one.
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

  // The rules column mixes folder headers and rules; find the item that
  // renders the n-th rule.
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

  // Hover and the cursor are the same thing: pointing at a row is a way of
  // selecting it. Moving the cursor by key scrolls the list under a
  // stationary pointer, though, and the row that slides beneath it would
  // otherwise steal the cursor straight back — so pointer selection waits
  // for the pointer to actually move.
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
    // A stable frame to measure against: rows move under the pointer as the
    // list scrolls, the viewport does not.
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
      // While the confirmation is up it owns the keyboard: the panel's own
      // cursor must not move under a dialog asking about the row it left.
      onMoveRequested: function(dx, dy) {
        if (root.pendingDeleteRule) {
          deleteConfirm.selectedIndex = deleteConfirm.selectedIndex === 0 ? 1 : 0
          return
        }
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: {
        if (root.pendingDeleteRule) {
          if (deleteConfirm.selectedIndex === 0) deleteConfirm.canceled()
          else deleteConfirm.confirmed()
          return
        }
        if (root.cursorActive) root.activateCursor()
      }
      onCloseRequested: {
        if (root.pendingDeleteRule) deleteConfirm.canceled()
        else if (root.profilePickerOpen) root.closeProfilePicker()
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (root.pendingDeleteRule) return
        if (t === "s") root.jumpTo(statsSection)
        else if (t === "a") root.jumpTo(activitySection)
        else if (t === "r") root.jumpTo(rulesSection)
        else if (t === "m") root.jumpTo(machineSection)
        else if (t === "g") root.jumpToEdge(false)
        else if (t === "G") root.jumpToEdge(true)
        else if (t === "?") root.legendOpen = !root.legendOpen
        else if (t === "p") root.toggleProfilePicker()
        else if (t === "o") Quickshell.execDetached(["omarchy-launch-browser", root.dashboardUrl])
        // Shift for the action, since the plain letter now names a section.
        else if (t === "R") controld.refresh()
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
        // over the content. The column below gives the width straight back, so
        // nothing shifts sideways.
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
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight
            function focusHero() { root.setCursor("header") }

            // The caret on the hero's meta line has nowhere of its own to take
            // a click: `PanelHero.meta` is a plain string. So the hero carries
            // the click, declared before it and therefore beneath it, which
            // leaves the mark and the switch their own. Clicks land here only
            // where nothing above accepts them.
            MouseArea {
              anchors.fill: parent
              enabled: controld.canEnforce && controld.installed
              hoverEnabled: enabled
              cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
              onClicked: root.toggleProfilePicker()
            }
            // The hero switch is a control, not a row: its hover is a
            // deliberate pointer act, so it does not need the gate.

            PanelHero {
              id: hero
              width: parent.width
              title: root.heroTitle
              meta: root.heroMeta
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconOpacity: controld.ready ? 1.0 : 0.5
              // The mark is the panel's identity and the dashboard is where
              // everything it cannot do lives, so the mark is the way there.
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
              // Everything else the hero used to carry has a key.
              trailingControl: Component {
                ToggleSwitch {
                  id: protectionSwitch
                  visible: controld.canPause && controld.installed
                  checked: controld.protectionActive
                  busy: controld.pauseBusy
                  foreground: hero.foreground
                  onHovered: function(on) { if (on) header.focusHero() }
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
          Text {
            visible: controld.lastError !== "" && !root.showEmptyState
            width: parent.width
            text: controld.lastError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            visible: controld.pauseError !== ""
            width: parent.width
            text: controld.pauseError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            visible: controld.lastHint !== "" && !root.showEmptyState
            width: parent.width
            text: controld.lastHint
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // Nothing to show until the CLI is installed and signed in, so the
          // panel spends its space saying how to get there.
          EmptyState {
            width: parent.width
            visible: controld.checkedInstall && !controld.installed
            title: "Install the Control D CLI"
            message: "This panel reads your account through cdctl. Install it, then sign in."
          }

          EmptyState {
            width: parent.width
            visible: controld.installed && controld.needsAuth
            title: "Sign in to Control D"
            message: "Run cdctl auth login --token-stdin with a token from the Control D dashboard, then reopen this panel."
          }

          // Paused on purpose looks identical to never set up, so the host
          // having a way to turn it back on is what tells them apart. The
          // action is the switch in the hero, so this state carries no button.
          EmptyState {
            width: parent.width
            visible: root.unprotected && controld.canPause
            title: "Control D is paused"
            message: "This machine is resolving DNS without it, so there is nothing to report until it is back on. Use the switch above."
            actionText: ""
          }

          // Signed in, but this machine's DNS goes somewhere else, so there is
          // no endpoint for the sections below to describe.
          EmptyState {
            width: parent.width
            visible: root.unprotected && !controld.canPause
            title: "No Control D resolver on this machine"
            message: "Nothing in this host's DNS config points at Control D, so there is no endpoint to report on. A router or network that filters upstream would not show up here either."
            actionText: "Open setup guide"
            actionUrl: root.guideUrl
          }

          // A Control D resolver we cannot name. The two causes need different
          // things from the reader, so the panel names which one it hit.
          EmptyState {
            width: parent.width
            visible: root.endpointUnknown
            title: "This machine could not be identified"
            message: controld.devicesError !== ""
              ? "Its DNS goes through Control D, but reading your endpoints failed, so the panel cannot tell which one this is."
              : "Its DNS goes through Control D, but that endpoint is not in this account. Check you are signed in to the account that owns it."
            detail: controld.devicesError
            actionText: "Open dashboard"
            actionUrl: root.dashboardUrl
          }

          // Machine facts, in the built-in panels' key/value idiom: attributes
          // sit under the hero without a header, and only the interactive
          // lists below get their own separated section.
          Column {
            id: machineSection
            visible: root.showEndpoint
            width: parent.width
            spacing: Style.spacing.labelGap

            FactGrid {
              width: parent.width

              // Read across, then down: what this machine is, how it talks,
              // what does the talking, and what it does with a domain no rule
              // covers. No Profile row: the hero's subtitle is that. The id is
              // the whole endpoint: every resolver address is that id plus a
              // constant suffix, and Protocol says which form it takes.
              InfoLabel { text: "Endpoint" }
              DetailValue {
                text: controld.endpoint ? controld.endpoint.id : "--"
                copyable: controld.endpoint !== null
                tooltipText: "Copy endpoint ID"
              }
              InfoLabel { text: "Protocol" }
              DetailValue { text: controld.endpointTransport !== "" ? controld.endpointTransport : "--" }

              // What on this machine talks to Control D, probed here rather
              // than taken from the account's record of the device. When the
              // probe names the endpoint but nothing that manages it, the row
              // says so and offers to have the setup reported.
              InfoLabel { text: "Resolver" }
              DetailValue {
                text: controld.resolverLine
                linkUrl: controld.resolverUnknown ? root.issuesUrl : ""
                tooltipText: "Resolver not recognised. Report your setup on GitHub so it can be added."
              }
              // The profile's default action: what happens to a domain that
              // matches no rule, filter or service.
              InfoLabel { text: "Unmatched" }
              DetailValue { text: controld.activeProfile ? Model.actionLabel(controld.activeProfile.defaultAction) : "--" }
            }
          }

          // The account's profiles, under the hero that names the one in force.
          // Only while picking: a list of what could be enforced is noise next
          // to what is.
          Column {
            id: profilePicker
            visible: root.profilePickerOpen
            width: parent.width
            spacing: Style.spacing.labelGap

            Repeater {
              model: root.profilePickerOpen ? controld.profiles : []

              // CursorSurface, so where the cursor is and what is in force are
              // two different paints. Its contract forbids reading the mouse
              // for colour: hover moves the panel's cursor, and the cursor is
              // what the row draws from, so there is one highlight on screen
              // however you are driving it.
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

                Text {
                  id: profileStatus
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  visible: profileRow.enforced
                  text: profileRow.switching ? "switching…" : "in force"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                MouseArea {
                  id: profileMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onEntered: root.setCursorFromPointer(profileRow.cursorKey, profileRow, { x: profileMouse.mouseX, y: profileMouse.mouseY })
                  onPositionChanged: function(mouse) { root.setCursorFromPointer(profileRow.cursorKey, profileRow, mouse) }
                  enabled: !controld.enforceBusy
                  onClicked: {
                    controld.setEnforcedProfile(profileRow.modelData.id)
                    root.closeProfilePicker()
                  }
                }
              }
            }
          }

          Text {
            width: parent.width
            visible: controld.enforceError !== ""
            text: controld.enforceError
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
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
            // the section's own title, as the destinations control sits with
            // its list.
            RowLayout {
              width: parent.width
              spacing: Style.space(8)

              PanelSectionHeader {
                text: "STATISTICS"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Item { Layout.fillWidth: true }

              ButtonGroup {
                options: Model.windowOptions()
                value: String(controld.statsHours)
                foreground: root.foreground
                accent: Color.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                onChanged: function(v) { controld.setStatsWindow(v) }
              }
            }

            Text {
              width: parent.width
              visible: root.statsCaption !== ""
              text: root.statsCaption
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
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

            Text {
              width: parent.width
              visible: controld.statsError !== ""
              text: controld.statsError
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            // The verdict governs the two lists directly beneath it, so it
            // sits tight against them rather than floating under the chart.
            Column {
              width: parent.width
              visible: controld.stats !== null
              spacing: Style.space(10)
              topPadding: Style.space(4)

              RowLayout {
                width: parent.width
                spacing: Style.space(8)

                PanelSectionHeader {
                  text: "BREAKDOWN"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                Item { Layout.fillWidth: true }

                ButtonGroup {
                  options: Model.actionOptions()
                  value: String(controld.statsAction)
                  foreground: root.foreground
                  accent: Color.accent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  onChanged: function(v) { controld.setStatsAction(v) }
                }
              }

              Text {
                width: parent.width
                visible: root.actionRows.length === 0 && controld.statsError === ""
                text: "Nothing " + root.actionWord + " in this window."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              MeterList {
                id: domainList
                width: parent.width
                title: "DOMAINS"
                rows: controld.stats ? controld.stats.domains : []
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

              RowLayout {
                width: parent.width
                spacing: Style.space(8)

                PanelSectionHeader {
                  text: "DESTINATIONS"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                Item { Layout.fillWidth: true }

                ButtonGroup {
                  options: [{ value: "networks", label: "Networks" }, { value: "countries", label: "Countries" }]
                  value: root.destinationView
                  foreground: root.foreground
                  accent: Color.accent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  onChanged: function(v) { root.destinationView = v }
                }
              }

              MeterList {
                id: destinationList
                width: parent.width
                rows: root.destinationRows
                cursorPrefix: "destination:"
                // Codes name nothing on their own; the copied value stays the
                // code the API reports.
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

            // The verdict governs the whole log, so it sits with the
            // section's own title, as the window does for statistics.
            RowLayout {
              width: parent.width
              spacing: Style.space(8)

              PanelSectionHeader {
                text: "ACTIVITY"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Item { Layout.fillWidth: true }

              ButtonGroup {
                options: Model.activityFilterOptions()
                value: controld.activityFilter
                foreground: root.foreground
                accent: Color.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                onChanged: function(v) { controld.setActivityFilter(v) }
              }
            }

            // One chip per verdict fills the title row, as it does under
            // STATISTICS and BREAKDOWN, so the switch takes a line of its own
            // rather than pushing the last chip off the panel.
            RowLayout {
              width: parent.width
              spacing: Style.space(8)

              Item { Layout.fillWidth: true }

              Text {
                Layout.alignment: Qt.AlignVCenter
                text: "Grouped"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
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

            Text {
              width: parent.width
              visible: text !== ""
              // A refused write outranks both: it is the one thing here the
              // reader just did, rather than something the window reports.
              text: controld.ruleError !== "" ? controld.ruleError
                : (controld.activityError !== "" ? controld.activityError
                  : (controld.activityLog.length === 0 ? root.emptyActivityLine : ""))
              color: controld.ruleError !== "" || controld.activityError !== "" ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Column {
              id: activityColumn
              width: parent.width
              spacing: Style.space(6)

              // The log repolls every fifteen seconds and new lookups arrive at
              // the top, so every row below shifts down -- under whatever the
              // pointer was aiming at. These rows write account rules, so that
              // is not a flicker, it is a rule against the wrong host. While
              // the pointer is in the list the rows it is choosing between hold
              // still, and the newer page lands once it leaves.
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

            SectionTitle {
              width: parent.width
              text: root.rulesTitle
              caption: root.rulesCaption
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

      // Keys are invisible by nature, so ? reveals them without spending
      // Over everything the panel draws, since it is asking about one row and
      // the rest must not be reachable while it does. Declared last so it sits
      // above the list, its scrim taking the clicks the rows would otherwise.
      ConfirmDialog {
        id: deleteConfirm
        anchors.fill: parent
        opened: root.pendingDeleteRule !== null
        message: root.pendingDeleteRule
          ? "Delete the rule for " + root.pendingDeleteRule.hostname + "?"
          : ""
        confirmText: "Delete"
        cancelText: "Keep"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onCanceled: root.pendingDeleteRule = null
        onConfirmed: {
          controld.deleteRule(root.pendingDeleteRule)
          root.pendingDeleteRule = null
        }
      }

      // room on a legend nobody asked for.
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

              Text {
                width: Style.space(30)
                horizontalAlignment: Text.AlignRight
                text: modelData.key
                color: Qt.darker(root.foreground, 1.25)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                text: modelData.what
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
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

  // A section header with an optional right-aligned caption. No icon: the
  // built-in panels label their sections with text alone.
  component SectionTitle: Item {
    id: sectionTitle
    property string text: ""
    property string caption: ""

    implicitHeight: Math.max(label.implicitHeight, captionText.implicitHeight)

    PanelSectionHeader {
      id: label
      anchors.left: parent.left
      text: sectionTitle.text
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    Text {
      id: captionText
      anchors.right: parent.right
      anchors.baseline: label.baseline
      visible: sectionTitle.caption !== ""
      text: sectionTitle.caption
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
      width: Math.min(implicitWidth, parent.width * 0.6)
      horizontalAlignment: Text.AlignRight
    }
  }


  component FolderRow: Item {
    id: folderRow
    property var group: null
    readonly property int ruleTotal: group ? group.rules.length : 0

    implicitHeight: folderInner.implicitHeight + Style.space(6)

    Row {
      id: folderInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        text: "󰉋"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        width: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        width: parent.width - Style.space(30)
        text: {
          var name = folderRow.group ? folderRow.group.name.toUpperCase() : ""
          var suffix = folderRow.ruleTotal + (folderRow.ruleTotal === 1 ? " RULE" : " RULES")
          if (folderRow.group && folderRow.group.folder && !folderRow.group.folder.enabled) suffix += " · DISABLED"
          return name + "  ·  " + suffix
        }
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        elide: Text.ElideRight
        anchors.verticalCenter: parent.verticalCenter
      }
    }
  }

  // One geometry for every key/value block, so a label in one lines up with
  // the label in the next. Sized rather than left to each grid's own content,
  // which is what made the second block sit a few pixels off the first.
  component FactGrid: GridLayout {
    columns: 4
    columnSpacing: Style.space(12)
    rowSpacing: Style.spacing.labelGap
  }

  component InfoLabel: Text {
    color: root.foreground
    opacity: 0.6
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    Layout.fillWidth: true
    Layout.preferredWidth: 3
  }

  component DetailValue: Text {
    id: detailValue
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    // Deliberately not elided. Every value here comes from a closed set -- an
    // endpoint id, a protocol name, a resolver from `RESOLVERS`, an action --
    // and letting the text keep its own width is what makes the grid lend the
    // long ones room from the labels. Eliding cut `systemd-resolved`, which
    // fits only because of that lending.
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

    Text {
      id: copyGlyph
      visible: detailValue.actionable
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: detailValue.linkUrl !== "" ? "󰏌" : "󰆏"
      color: detailValue.color
      opacity: valueMouse.containsMouse ? 1.0 : 0.45
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption

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

  // A titled list of rows whose background is filled in proportion to the
  // biggest row, so the bar is the row rather than a rule beneath it.
  component MeterList: Column {
    id: meterList
    property string title: ""
    property var rows: []
    // Filter ids arrive as slugs and country codes as two letters; both read
    // badly raw. The copied value is always what the API reported.
    property bool pretty: false
    property string labelFor: ""
    // Only rows whose value can be acted on elsewhere offer to be copied.
    property bool copyable: false
    // Set for a list the cursor walks; rows key off it by index.
    property string cursorPrefix: ""

    visible: rows.length > 0
    spacing: Style.space(1)

    // A level below the block headers above it: same shape, less weight.
    Text {
      text: meterList.title
      visible: meterList.title !== ""
      color: Qt.darker(root.foreground, 1.55)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
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
  // day. The bar keeps a fixed share of the row so long domain names have
  // room to read.
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

    Text {
      id: rowLabel
      anchors.left: parent.left
      anchors.right: meterTrack.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      text: meterRow.label
      color: meterRow.hot ? root.foreground : Qt.darker(root.foreground, 1.25)
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
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

    Text {
      id: rowValue
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(38)
      horizontalAlignment: Text.AlignRight
      text: Model.formatCount(meterRow.hits)
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: meterRow.interactive ? Qt.PointingHandCursor : Qt.ArrowCursor
      acceptedButtons: meterRow.interactive ? Qt.LeftButton : Qt.NoButton
      onEntered: if (meterRow.cursorKey !== "") root.setCursorFromPointer(meterRow.cursorKey, meterRow, { x: rowMouse.mouseX, y: rowMouse.mouseY })
      onPositionChanged: function(mouse) { if (meterRow.cursorKey !== "") root.setCursorFromPointer(meterRow.cursorKey, meterRow, mouse) }
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

    spacing: Style.space(6)

    Text {
      width: emptyState.width
      text: emptyState.title
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.subtitle
      wrapMode: Text.WordWrap
    }

    Text {
      width: emptyState.width
      text: emptyState.message
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      wrapMode: Text.WordWrap
    }

    Text {
      width: emptyState.width
      visible: emptyState.detail !== ""
      text: emptyState.detail
      color: root.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }

    Button {
      visible: emptyState.actionText !== ""
      text: emptyState.actionText
      bordered: true
      foreground: root.foreground
      accent: Color.accent
      fontFamily: root.fontFamily
      fontSize: Style.font.body
      topPadding: Style.space(4)
      onClicked: Quickshell.execDetached(["omarchy-launch-browser", emptyState.actionUrl])
    }
  }

  // One lookup: what was asked, what happened to it, and when. The A/AAAA
  // pair of a single lookup arrives already collapsed.
  // The foot of a list that draws short: what is left, and a way to see it.
  // Reads as a control rather than a row, since it is the one thing there that
  // acts on the list instead of belonging to it.
  component MoreRow: Item {
    id: moreRow
    property string text: ""
    property string cursorKey: ""
    signal activated()
    readonly property bool hasCursor: cursorKey !== "" && root.cursorActive && root.cursorKey === cursorKey
    readonly property bool hot: moreMouse.containsMouse || hasCursor

    implicitHeight: moreLabel.implicitHeight + Style.spacing.sm * 2

    Text {
      id: moreLabel
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: moreRow.text
      color: moreRow.hot ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption

      Behavior on color {
        ColorAnimation { duration: 120; easing.type: Easing.OutQuad }
      }
    }

    MouseArea {
      id: moreMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.setCursorFromPointer(moreRow.cursorKey, moreRow, { x: moreMouse.mouseX, y: moreMouse.mouseY })
      onPositionChanged: function(mouse) { root.setCursorFromPointer(moreRow.cursorKey, moreRow, mouse) }
      onClicked: moreRow.activated()
    }
  }

  component ActivityRow: Item {
    id: activityRow
    property var query: null
    property string cursorKey: ""
    readonly property string question: query ? query.question : ""
    readonly property bool blocked: query && query.action === 0
    readonly property bool hasCursor: cursorKey !== "" && root.cursorActive && root.cursorKey === cursorKey
    // The glyph's own hover counts: without it, moving onto the control takes
    // hover off the row, and a control that reads the row's hover would put
    // itself away exactly as the pointer arrives.
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

    implicitHeight: activityText.implicitHeight + Style.spacing.sm * 2

    // Declared before the row's contents and therefore beneath them, so the
    // action button takes its own clicks and everything else falls through to
    // the row. Filling the row over the top would swallow the button.
    MouseArea {
      id: activityMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: if (activityRow.cursorKey !== "") root.setCursorFromPointer(activityRow.cursorKey, activityRow, { x: activityMouse.mouseX, y: activityMouse.mouseY })
      onPositionChanged: function(mouse) { if (activityRow.cursorKey !== "") root.setCursorFromPointer(activityRow.cursorKey, activityRow, mouse) }
      onClicked: controld.copyToClipboard(activityRow.question)
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)

      // The verdict, and the control that reverses it. At rest the glyph is
      // where the host stands now -- the log's verdict, or the override this
      // profile holds over it. Under the pointer or the cursor it becomes what
      // clicking will make it, which on an overridden row is the way back. So
      // the glyph answers "what is it" until you reach for it, then "what will
      // this do", and the accent says the answer came from a rule you wrote
      // rather than from the log.
      Item {
        // A fixed cell, not the glyph's own width: these glyphs do not all
        // advance the same, so sizing to the one on show slid the hostname
        // sideways every time the pointer changed it.
        Layout.preferredWidth: Style.space(22)
        Layout.preferredHeight: verdictGlyph.implicitHeight
        Layout.alignment: Qt.AlignVCenter

        Text {
          id: verdictGlyph
          readonly property string verdict: activityRow.verdictName
          // Where the host stands: the override if this profile holds one,
          // else what the log recorded.
          readonly property string atRest: activityRow.applied ? activityRow.intent.action : verdict
          anchors.centerIn: parent
          // The glyph's own hover, not the row's: crossing a row on the way
          // somewhere else should not make every verdict it passes flicker
          // into its opposite. On reach, a row with no rule shows the verdict
          // the click writes -- exact, since the rule is what decides it --
          // and a row with one shows undo, which is all the click promises.
          text: {
            if (!activityRow.actionable || !activityRow.glyphReached)
              return Model.actionGlyph(atRest)
            return activityRow.applied ? Model.UNDO_GLYPH : Model.actionGlyph(activityRow.intent.action)
          }
          // Accent only at rest, where it is the one thing telling your rule
          // from an ordinary bypass. Under the pointer the glyph has already
          // changed shape, and saying it twice just makes it louder.
          color: activityRow.glyphReached && activityRow.actionable ? root.foreground
            : (activityRow.applied ? Color.accent
              : (activityRow.blocked ? root.foreground : root.dim))
          opacity: activityRow.pending ? 0.4 : 1.0
          font.family: root.fontFamily
          font.pixelSize: Style.font.icon

          Behavior on color { ColorAnimation { duration: 60 } }
        }

        MouseArea {
          id: verdictMouse
          anchors.fill: parent
          // Not disabled while a write is in flight: taking the mouse area
          // away under the pointer drops its hover, and giving it back does
          // not restore it until the pointer moves -- so the row it just acted
          // on would go back to showing its resting glyph. `applyRuleIntent`
          // turns a second click away on its own.
          enabled: activityRow.actionable
          hoverEnabled: enabled
          cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
          onEntered: root.hoveredGlyphHost = activityRow.question
          onExited: if (root.hoveredGlyphHost === activityRow.question) root.hoveredGlyphHost = ""
          onClicked: controld.applyRuleIntent(activityRow.intent)
        }

        PanelToolTip {
          visible: activityRow.glyphReached
          text: activityRow.applied
            ? ("Remove this " + activityRow.intent.action + " rule")
            : (activityRow.intent.action + " this host")
          fontFamily: root.fontFamily
        }
      }

      ColumnLayout {
        id: activityText
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: activityRow.question
          color: activityRow.hot ? root.foreground : Qt.darker(root.foreground, 1.25)
          // Struck through, not dimmed: dimming reads as "less important",
          // which a row you just acted on is not. A line through it says the
          // verdict it records no longer stands.
          font.strikeout: activityRow.superseded
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideMiddle
        }

        Text {
          Layout.fillWidth: true
          text: Model.activityDetail(activityRow.query)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Text {
        text: Model.clockTime(activityRow.query ? activityRow.query.time : "")
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
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

    hasCursor: root.cursorActive && root.cursorKey === "rule:" + rowIndex
    foreground: root.foreground
    fill: root.hoverFill

    implicitHeight: ruleContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      id: ruleMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.setCursorFromPointer("rule:" + ruleRow.rowIndex, ruleRow, { x: ruleMouse.mouseX, y: ruleMouse.mouseY })
      onPositionChanged: function(mouse) { root.setCursorFromPointer("rule:" + ruleRow.rowIndex, ruleRow, mouse) }
      onClicked: if (ruleRow.rule) controld.copyToClipboard(ruleRow.rule.hostname)
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(8)

      // The rule's action, and the switch that turns the rule off. At rest it
      // says what the rule does; reaching for it says what the click does,
      // which is not the same question -- toggling leaves the action alone.
      Item {
        Layout.preferredWidth: Style.space(22)
        Layout.preferredHeight: ruleGlyph.implicitHeight
        Layout.alignment: Qt.AlignVCenter

        Text {
          id: ruleGlyph
          anchors.centerIn: parent
          // Pause on a rule that is running, play on one that is not: the
          // glyph says which way the click goes, not merely that it toggles.
          text: ruleRow.glyphReached
            ? (ruleRow.ruleEnabled ? Model.PAUSE_GLYPH : Model.PLAY_GLYPH)
            : Model.actionGlyph(ruleRow.rule ? ruleRow.rule.action : "")
          color: ruleRow.ruleEnabled || ruleRow.glyphReached ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.icon
          opacity: ruleRow.pending ? 0.4 : (ruleRow.ruleEnabled || ruleRow.glyphReached ? 1.0 : 0.6)
        }

        MouseArea {
          id: ruleGlyphMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onEntered: root.hoveredRuleHost = ruleRow.hostname
          onExited: if (root.hoveredRuleHost === ruleRow.hostname) root.hoveredRuleHost = ""
          onClicked: controld.toggleRule(ruleRow.rule)
        }

        PanelToolTip {
          visible: ruleRow.glyphReached
          text: ruleRow.ruleEnabled ? "Pause this rule" : "Resume this rule"
          fontFamily: root.fontFamily
        }
      }

      ColumnLayout {
        id: ruleContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: ruleRow.hostname
          color: ruleRow.ruleEnabled ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
          // The same line the activity log draws through a verdict a rule has
          // overruled. A rule switched off is the same claim about itself.
          font.strikeout: !ruleRow.ruleEnabled
        }

        Text {
          Layout.fillWidth: true
          text: Model.ruleDetail(ruleRow.rule)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      // Always drawn, never revealed on hover: a control that appears under
      // the pointer is a control that can move out from under it. Quiet until
      // reached, and urgent-tinted there, since this is the one action in the
      // panel that cannot be taken back.
      PanelActionButton {
        id: ruleDelete
        iconText: Model.TRASH_GLYPH
        // Silenced while the confirmation is up: the pointer is still on this
        // button, and its tooltip would sit over the answer it is asking for.
        tooltipText: root.pendingDeleteRule ? "" : "Delete this rule"
        foreground: root.foreground
        hoverColor: root.urgent
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        opacity: ruleRow.hasCursor || ruleDeleteHovered ? 1.0 : 0.35
        Layout.alignment: Qt.AlignVCenter
        onHovered: function(on) { ruleRow.ruleDeleteHovered = on }
        onClicked: root.askDeleteRule(ruleRow.rule)
      }
    }

    PanelToolTip {
      visible: ruleMouse.containsMouse && !ruleRow.glyphReached
      text: ruleRow.ruleEnabled ? "Copy hostname" : "Rule is off · copy hostname"
      fontFamily: root.fontFamily
    }
  }
}
