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
    && (controld.activity.length > 0 || controld.activityError !== "")
  readonly property bool showStats: controld.ready && machineMode && controld.statsEnabled
    && (controld.statsAvailable || controld.statsError !== "")
  property bool legendOpen: false
  // Only the keys that exist in the state being shown: a legend that lists
  // what does nothing here is worse than none.
  readonly property var legendKeys: {
    var keys = [{ key: "j/k", what: "move" }, { key: "enter", what: "activate" }, { key: "y", what: "copy" }]
    if (showStats) keys.push({ key: "s", what: "statistics" })
    if (showRules) keys.push({ key: "r", what: "rules" })
    if (showActivity) keys.push({ key: "a", what: "activity" })
    if (showEndpoint) keys.push({ key: "m", what: "machine" })
    keys.push({ key: "g/G", what: "top/bottom" }, { key: "o", what: "dashboard" },
      { key: "R", what: "refresh" }, { key: "esc", what: "close" })
    return keys
  }

  // The log is drawn short and expands in place. Rows past the fold are
  // already fetched, so this costs nothing but the space.
  property bool activityExpanded: false
  readonly property var visibleActivity: {
    var all = controld.activity
    if (activityExpanded || all.length <= controld.activityRows) return all
    return all.slice(0, controld.activityRows)
  }
  readonly property int hiddenActivity: controld.activity.length - visibleActivity.length
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
  readonly property string statsCaption: {
    if (!controld.statsAvailable) return "analytics off for this endpoint"
    if (controld.statsLoading) return "loading…"
    return ""
  }
  // Only rule rows take the cursor; folder headers are labels.
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
    if (controld.endpoint) return Model.endpointLine(controld.endpoint, "")
    // With no endpoint to name, the empty state below carries the reason. The
    // hero says which account is signed in instead, which is what the reader
    // needs to act on it, and is short enough not to elide.
    return controld.statusText
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
    if (showRules) {
      for (var r = 0; r < cursorRules.length; r++)
        items.push({ key: "rule:" + r, kind: "rule", index: r, value: cursorRules[r].hostname })
    }
    if (showActivity) {
      for (var a = 0; a < visibleActivity.length; a++)
        items.push({ key: "activity:" + a, kind: "activity", index: a, value: visibleActivity[a].question })
      if (activityExpandable) items.push({ key: "activity:more", kind: "more", value: "" })
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

  function selectedRule() {
    var entry = currentCursor()
    if (!entry || entry.kind !== "rule") return null
    return cursorRules[entry.index] || null
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
    if (entry.kind === "header") { controld.refresh(); return }
    if (entry.kind === "more") { root.activityExpanded = !root.activityExpanded; return }
    if (entry.kind === "reading") return
    if (String(entry.value || "") !== "") controld.copyToClipboard(entry.value)
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
    if (!opened) return
    cursorActive = false
    cursorKey = "header"
    activityExpanded = false
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
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "s") root.jumpTo(statsSection)
        else if (t === "a") root.jumpTo(activitySection)
        else if (t === "r") root.jumpTo(rulesSection)
        else if (t === "m") root.jumpTo(machineSection)
        else if (t === "g") root.jumpToEdge(false)
        else if (t === "G") root.jumpToEdge(true)
        else if (t === "?") root.legendOpen = !root.legendOpen
        else if (t === "o") Quickshell.execDetached(["omarchy-launch-browser", root.dashboardUrl])
        // Shift for the action, since the plain letter now names a section.
        else if (t === "R") controld.refresh()
        else if (t === "y" || t === "Y") root.yank()
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
            // Reached from the hero's trailingControl, whose `root` is the
            // PanelHero rather than this Panel.
            readonly property bool ringVisible: root.headerHasCursor
            function focusHero() { root.setCursor("header") }
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
              iconComponent: Component {
                ControldIcon {
                  iconSize: Style.font.display
                  color: root.iconColor
                  badgeColor: root.urgent
                  crossed: (controld.checkedInstall && !controld.installed) || root.unprotected
                  warning: controld.installed && controld.needsAuth
                }
              }

              PanelToolTip {
                visible: heroHover.hovered && controld.statusText !== ""
                text: controld.statusText
                fontFamily: root.fontFamily
              }

              HoverHandler { id: heroHover }

              trailingControl: Component {
                Row {
                  spacing: Style.space(2)

                  // Everything this panel cannot do lives in the dashboard,
                  // so it is one click away rather than a URL to remember.
                  PanelActionButton {
                    visible: controld.installed
                    iconText: "󰏌"
                    tooltipText: "Open Control D dashboard"
                    foreground: hero.foreground
                    fontFamily: hero.fontFamily
                    onHovered: function(on) { if (on) header.focusHero() }
                    onClicked: Quickshell.execDetached(["omarchy-launch-browser", root.dashboardUrl])
                  }

                  PanelActionButton {
                    id: refreshButton
                    visible: controld.installed
                    iconText: "󰑐"
                    tooltipText: "Refresh"
                    foreground: hero.foreground
                    fontFamily: hero.fontFamily
                    hasCursor: header.ringVisible
                    enabled: !controld.busy
                    opacity: controld.busy ? 0.45 : 1.0
                    onHovered: function(on) { if (on) header.focusHero() }
                    onClicked: controld.refresh()

                    SequentialAnimation on opacity {
                      running: controld.busy
                      loops: Animation.Infinite
                      NumberAnimation { to: 1.0; duration: 420; easing.type: Easing.InOutQuad }
                      NumberAnimation { to: 0.45; duration: 420; easing.type: Easing.InOutQuad }
                    }
                  }
                }
              }
            }
          }

          Text {
            visible: controld.lastError !== ""
            width: parent.width
            text: controld.lastError
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

          // Signed in, but this machine's DNS goes somewhere else, so there is
          // no endpoint for the sections below to describe.
          EmptyState {
            width: parent.width
            visible: root.unprotected
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

              InfoLabel { text: "Profile" }
              DetailValue { text: controld.activeProfile ? controld.activeProfile.name : "--" }
              // The profile's default action governs domains that match no
              // rule, filter, or service.
              InfoLabel { text: "Unmatched" }
              DetailValue { text: controld.activeProfile ? Model.actionLabel(controld.activeProfile.defaultAction) : "--" }

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

              InfoLabel { text: "Filters" }
              DetailValue { text: controld.activeProfile ? String(controld.activeProfile.enabledFilters) : "--" }
              InfoLabel { text: "Services" }
              DetailValue { text: controld.activeProfile ? String(controld.activeProfile.enabledServices) : "--" }

              // The id is the whole content: every endpoint's resolver is that
              // id plus a constant suffix, and Protocol already says which form
              // it takes.
              InfoLabel { text: "Endpoint" }
              DetailValue {
                text: controld.endpoint ? controld.endpoint.id : "--"
                copyable: controld.endpoint !== null
                tooltipText: "Copy endpoint ID"
              }
              Item { Layout.fillWidth: true }
              Item { Layout.fillWidth: true }
            }
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

          PanelSeparator {
            visible: root.showActivity
            foreground: root.foreground
          }

          Column {
            id: activitySection
            visible: root.showActivity
            width: parent.width
            spacing: Style.space(8)

            SectionTitle {
              width: parent.width
              text: "ACTIVITY"
              caption: controld.activityError !== "" ? controld.activityError
                : (controld.activity.length === 0 ? "no queries yet" : "")
            }

            Column {
              id: activityColumn
              width: parent.width
              spacing: Style.space(6)

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
                onActivated: root.activityExpanded = !root.activityExpanded
              }
            }
          }
        }
      }

      // Keys are invisible by nature, so ? reveals them without spending
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

  component InfoValue: Text {
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component DetailValue: InfoValue {
    id: detailValue
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
    readonly property bool hot: activityMouse.containsMouse || hasCursor

    implicitHeight: activityText.implicitHeight + Style.spacing.sm * 2

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)

      Text {
        text: Model.actionGlyph(Model.actionName(activityRow.query ? activityRow.query.action : -1))
        color: activityRow.blocked ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        id: activityText
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: activityRow.question
          color: activityRow.hot ? root.foreground : Qt.darker(root.foreground, 1.25)
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

    MouseArea {
      id: activityMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: if (activityRow.cursorKey !== "") root.setCursorFromPointer(activityRow.cursorKey, activityRow, { x: activityMouse.mouseX, y: activityMouse.mouseY })
      onPositionChanged: function(mouse) { if (activityRow.cursorKey !== "") root.setCursorFromPointer(activityRow.cursorKey, activityRow, mouse) }
      onClicked: controld.copyToClipboard(activityRow.question)
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

      Text {
        text: Model.actionGlyph(ruleRow.rule ? ruleRow.rule.action : "")
        color: ruleRow.ruleEnabled ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
        opacity: ruleRow.ruleEnabled ? 1.0 : 0.6
      }

      ColumnLayout {
        id: ruleContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: ruleRow.rule ? ruleRow.rule.hostname : ""
          color: ruleRow.ruleEnabled ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
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

      PanelActionButton {
        iconText: "󰆏"
        tooltipText: "Copy hostname"
        foreground: root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: if (ruleRow.rule) controld.copyToClipboard(ruleRow.rule.hostname)
      }
    }

    PanelToolTip {
      visible: ruleMouse.containsMouse
      text: ruleRow.ruleEnabled ? "Copy hostname" : "Rule is disabled · copy hostname"
      fontFamily: root.fontFamily
    }
  }
}
