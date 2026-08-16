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

  property string focusSection: "header"
  property int profileIndex: 0
  property int ruleIndex: 0
  property bool cursorActive: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "transparent"

  // Machine mode: this panel describes the endpoint and the profile it
  // enforces. Browse mode is the fallback for a machine that is not on
  // Control D DNS, where there is no endpoint to describe.
  readonly property bool machineMode: controld.endpoint !== null
  readonly property bool showEndpoint: controld.ready && machineMode
  readonly property bool showProfiles: controld.ready && !machineMode && controld.profiles.length > 0
  readonly property bool showRules: controld.ready && controld.activeProfile !== null
  readonly property bool unprotected: controld.ready && controld.resolverChecked && !controld.usingControld
  // Where to send someone who has neither the CLI nor an account set up.
  readonly property string guideUrl: "https://github.com/joaodrp/omarchy-controld-panel#readme"
  readonly property bool showEmptyState: controld.checkedInstall
    && (!controld.installed || controld.needsAuth)
  readonly property bool showActivity: controld.ready && machineMode && controld.activityEnabled
    && (controld.activity.length > 0 || controld.activityError !== "")
  readonly property bool showStats: controld.ready && machineMode && controld.statsEnabled
    && (controld.statsAvailable || controld.statsError !== "")
  property bool legendOpen: false
  // Only the keys that exist in the state being shown: a legend that lists
  // what does nothing here is worse than none.
  readonly property var legendKeys: {
    var keys = [{ key: "j/k", what: "move" }, { key: "enter", what: "copy" }]
    if (showStats) keys.push({ key: "s", what: "statistics" })
    if (showActivity) keys.push({ key: "a", what: "activity" })
    if (showRules) keys.push({ key: "r", what: "rules" })
    if (showEndpoint) keys.push({ key: "m", what: "machine" }, { key: "y", what: "endpoint id" })
    if (showProfiles) keys.push({ key: "p", what: "next profile" })
    keys.push({ key: "g/G", what: "top/bottom" }, { key: "R", what: "refresh" }, { key: "esc", what: "close" })
    return keys
  }

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
  readonly property bool headerHasCursor: cursorActive && focusSection === "header" && controld.installed
  readonly property color iconColor: controld.ready && !unprotected ? foreground : dim
  readonly property color barIconColor: controld.ready && !unprotected ? barForeground : Qt.darker(barForeground, 1.55)
  // The hero names this machine's endpoint and what it enforces; the account
  // line is the fallback when no Control D resolver is in use here.
  readonly property string heroTitle: {
    if (controld.endpoint) return controld.endpoint.name
    return controld.selectedProfile ? controld.selectedProfile.name : "Control D"
  }
  readonly property string heroMeta: {
    if (!controld.installed) return "cdctl is not installed"
    if (controld.needsAuth) return "Not authenticated"
    if (controld.refreshing && !controld.authenticated) return "Checking…"
    if (controld.endpoint) return Model.endpointLine(controld.endpoint, "")
    if (root.unprotected) return "This machine is not using Control D DNS"
    return controld.statusText
  }
  readonly property string rulesCaption: {
    if (controld.loadingRules && controld.rules.length === 0) return "Loading rules…"
    var c = controld.ruleCount
    if (c.total === 0) return "No custom rules in this profile."
    return c.enabled + " of " + c.total + " enabled"
  }
  // In machine mode the section above already names the profile these rules
  // belong to; in browse mode the profile list does.
  readonly property string rulesTitle: "RULES"

  function cursorRuleList() {
    var rows = controld.ruleRows
    var out = []
    for (var i = 0; i < rows.length; i++) if (rows[i].kind === "rule") out.push(rows[i].rule)
    return out
  }

  function selectedProfileRow() {
    if (controld.profiles.length === 0) return null
    return controld.profiles[Math.max(0, Math.min(profileIndex, controld.profiles.length - 1))]
  }

  function selectedRule() {
    if (cursorRules.length === 0) return null
    return cursorRules[Math.max(0, Math.min(ruleIndex, cursorRules.length - 1))]
  }

  function persistProfile(id) {
    if (!root.bar || !root.bar.shell || typeof root.bar.shell.updateEntryInline !== "function") return
    var entry = { id: root.moduleName }
    for (var key in settings) if (key !== "id") entry[key] = settings[key]
    entry.profile = String(id || "")
    root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function ensureCursor() {
    if (profileIndex >= controld.profiles.length) profileIndex = Math.max(0, controld.profiles.length - 1)
    if (ruleIndex >= cursorRules.length) ruleIndex = Math.max(0, cursorRules.length - 1)
    if (focusSection === "profiles" && !showProfiles) focusSection = "header"
    if (focusSection === "rules" && (!showRules || cursorRules.length === 0)) focusSection = showProfiles ? "profiles" : "header"
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    ensureCursor()
    if (dy !== 0) {
      if (focusSection === "header") {
        if (dy > 0) {
          if (showProfiles) focusSection = "profiles"
          else if (cursorRules.length > 0) focusSection = "rules"
        }
      } else if (focusSection === "profiles") {
        if (dy < 0) {
          if (profileIndex <= 0) focusSection = "header"
          else profileIndex--
        } else {
          if (profileIndex < controld.profiles.length - 1) profileIndex++
          else if (cursorRules.length > 0) focusSection = "rules"
        }
      } else if (focusSection === "rules") {
        if (dy < 0) {
          if (ruleIndex <= 0) focusSection = showProfiles ? "profiles" : "header"
          else ruleIndex--
        } else if (ruleIndex < cursorRules.length - 1) {
          ruleIndex++
        }
      }
    }
    ensureCursor()
    scrollCursorIntoView()
  }

  function activateCursor() {
    ensureCursor()
    if (focusSection === "header") controld.refresh()
    else if (focusSection === "profiles") {
      var p = selectedProfileRow()
      if (p) controld.selectProfile(p.id)
    } else if (focusSection === "rules") {
      var r = selectedRule()
      if (r) controld.copyToClipboard(r.hostname)
    }
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
    cursorActive = section === rulesSection
    if (section === rulesSection) {
      focusSection = "rules"
      ruleIndex = 0
    }
    var y = section.mapToItem(panelFlick.contentItem, 0, 0).y
    var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
    panelFlick.contentY = Math.max(0, Math.min(maxY, y - Style.space(8)))
  }

  function jumpToEdge(bottom) {
    if (!panelFlick) return
    cursorActive = false
    panelFlick.contentY = bottom
      ? Math.max(0, panelFlick.contentHeight - panelFlick.height)
      : 0
  }

  function scrollCursorIntoView() {
    if (focusSection === "rules") {
      var target = ruleRowItem(ruleIndex)
      if (target) scrollItemIntoView(target)
    } else if (focusSection === "profiles" && profileColumn && profileIndex >= 0 && profileIndex < profileColumn.children.length) {
      scrollItemIntoView(profileColumn.children[profileIndex])
    } else if (focusSection === "header") {
      panelFlick.contentY = 0
    }
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

  function setHeaderCursor() {
    cursorActive = true
    focusSection = "header"
  }

  function setProfileCursor(index) {
    cursorActive = true
    focusSection = "profiles"
    profileIndex = index
  }

  function setRuleCursor(index) {
    cursorActive = true
    focusSection = "rules"
    ruleIndex = index
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    controld.statsWanted = opened
    legendOpen = false
    if (!opened) return
    cursorActive = false
    if (panelFlick) panelFlick.contentY = 0
    controld.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  onRuleIndexChanged: scrollCursorIntoView()
  onProfileIndexChanged: scrollCursorIntoView()
  onShowProfilesChanged: ensureCursor()
  onShowRulesChanged: ensureCursor()
  onCursorRulesChanged: ensureCursor()

  Service {
    id: controld
    settings: root.settings
    onProfileSelected: function(id) { root.persistProfile(id) }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { controld.refresh(); return "ok" }
    function profile(): string { return controld.selectedProfile ? controld.selectedProfile.name : "" }
    function selectProfile(id: string): string { controld.selectProfile(id); return "ok" }
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
          iconSize: Style.space(12)
          color: root.barIconColor
          badgeColor: root.urgent
          crossed: (controld.checkedInstall && !controld.installed) || root.unprotected
          warning: controld.installed && controld.needsAuth
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton && !root.machineMode) controld.selectNextProfile(1)
      else if (buttonCode === Qt.MiddleButton) controld.refresh()
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
        // Shift for the action, since the plain letter now names a section.
        else if (t === "R") controld.refresh()
        else if (t === "p" || t === "P") { if (!root.machineMode) controld.selectNextProfile(1) }
        else if (t === "c" || t === "C") controld.copyToClipboard(root.selectedRule() ? root.selectedRule().hostname : "")
        else if (t === "y" || t === "Y") controld.copyToClipboard(controld.endpoint ? controld.endpoint.id : "")
      }

      Flickable {
        id: panelFlick
        anchors.left: parent.left
        anchors.right: parent.right
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
          width: panelFlick.width
          spacing: Style.space(12)

          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight
            // Reached from the hero's trailingControl, whose `root` is the
            // PanelHero rather than this Panel.
            readonly property bool ringVisible: root.headerHasCursor
            function focusHero() { root.setHeaderCursor() }

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

          // Machine facts, in the built-in panels' key/value idiom: attributes
          // sit under the hero without a header, and only the interactive
          // lists below get their own separated section.
          Column {
            id: machineSection
            visible: root.showEndpoint
            width: parent.width
            spacing: Style.spacing.labelGap

            GridLayout {
              width: parent.width
              columns: 4
              columnSpacing: Style.space(20)
              rowSpacing: Style.spacing.labelGap

              InfoLabel { text: "Profile" }
              DetailValue { text: controld.activeProfile ? controld.activeProfile.name : "--" }
              // The profile's default action governs domains that match no
              // rule, filter, or service.
              InfoLabel { text: "Unmatched" }
              DetailValue { text: controld.activeProfile ? Model.actionLabel(controld.activeProfile.defaultAction) : "--" }

              InfoLabel { text: "Protocol" }
              DetailValue { text: controld.endpointTransport !== "" ? controld.endpointTransport : "--" }
              InfoLabel { text: "Daemon" }
              DetailValue { text: controld.endpoint && controld.endpoint.ctrldVersion !== "" ? "ctrld " + controld.endpoint.ctrldVersion : "--" }

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

            GridLayout {
              width: parent.width
              visible: controld.stats !== null
              columns: 4
              columnSpacing: Style.space(20)
              rowSpacing: Style.spacing.labelGap

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
                width: parent.width
                title: "DOMAINS"
                rows: controld.stats ? controld.stats.domains : []
                // A hostname is the one value here that goes straight into
                // `cdctl rule create`, a browser, or a dig.
                copyable: true
              }

              MeterList {
                width: parent.width
                title: "FILTERS"
                rows: controld.stats ? controld.stats.filters : []
                pretty: true
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
                width: parent.width
                rows: root.destinationRows
                // Codes name nothing on their own; the copied value stays the
                // code the API reports.
                labelFor: root.destinationView === "countries" ? "country" : ""
              }
            }
          }

          PanelSeparator {
            visible: root.showProfiles
            foreground: root.foreground
          }

          Column {
            visible: root.showProfiles
            width: parent.width
            spacing: Style.space(10)

            SectionTitle {
              width: parent.width
              text: "PROFILES"
            }

            Column {
              id: profileColumn
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: controld.profiles
                ProfileRow {
                  required property var modelData
                  required property int index
                  width: profileColumn.width
                  profile: modelData
                  rowIndex: index
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
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: controld.activity
                ActivityRow {
                  required property var modelData
                  width: parent.width
                  query: modelData
                }
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
                model: controld.ruleRows
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

  // Position of a rule among rule rows only, given its index in ruleRows.
  function ruleOrdinal(rowsIndex) {
    var rows = controld.ruleRows
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

  // One "<icon> <count>" pair on a profile row, mirroring the dashboard's
  // Filters / Services / Rules columns.
  component CountBadge: Row {
    id: badge
    property string icon: ""
    property int count: 0
    property bool highlighted: false

    spacing: Style.space(4)

    DashIcon {
      anchors.verticalCenter: parent.verticalCenter
      name: badge.icon
      iconSize: Style.font.caption
      color: root.dim
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: badge.count
      color: badge.count > 0 ? Qt.darker(root.foreground, 1.25) : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  component ProfileRow: CursorSurface {
    id: profileRow
    property var profile: null
    property int rowIndex: 0
    readonly property bool selectedProfile: profile && controld.selectedProfile && controld.selectedProfile.id === profile.id
    readonly property bool loading: selectedProfile && controld.loadingRules
    readonly property bool enforcedHere: profile && controld.endpointProfileId !== "" && controld.endpointProfileId === profile.id

    hasCursor: root.cursorActive && root.focusSection === "profiles" && root.profileIndex === rowIndex
    current: selectedProfile
    foreground: root.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill

    implicitHeight: profileInner.implicitHeight + Style.spacing.xl

    Row {
      id: profileInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Item {
        width: Style.space(22)
        height: Style.font.body
        anchors.verticalCenter: parent.verticalCenter
        opacity: profileRow.loading ? 0.45 : 1.0

        DashIcon {
          anchors.centerIn: parent
          name: "profiles"
          iconSize: Style.font.body
          color: profileRow.selectedProfile ? root.foreground : root.dim
        }

        SequentialAnimation on opacity {
          running: profileRow.loading
          loops: Animation.Infinite
          NumberAnimation { to: 1.0; duration: 420; easing.type: Easing.InOutQuad }
          NumberAnimation { to: 0.45; duration: 420; easing.type: Easing.InOutQuad }
        }
      }

      Column {
        width: parent.width - Style.space(30)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Row {
          width: parent.width
          spacing: Style.space(6)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: profileRow.profile ? profileRow.profile.name : ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: profileRow.selectedProfile
            elide: Text.ElideRight
          }

          // The profile this machine's endpoint actually enforces, which is
          // not necessarily the one being browsed.
          DashIcon {
            anchors.verticalCenter: parent.verticalCenter
            visible: profileRow.enforcedHere
            name: "endpoints"
            iconSize: Style.font.caption
            color: root.dim
          }
        }

        Row {
          spacing: Style.space(10)

          CountBadge {
            icon: "rules"
            count: profileRow.profile ? profileRow.profile.enabledRules : 0
          }

          CountBadge {
            icon: "filters"
            count: profileRow.profile ? profileRow.profile.enabledFilters : 0
          }

          CountBadge {
            icon: "services"
            count: profileRow.profile ? profileRow.profile.enabledServices : 0
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: profileRow.profile && !profileRow.profile.enabled
            text: "disabled"
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }

    MouseArea {
      id: profileMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.setProfileCursor(profileRow.rowIndex)
      onClicked: if (profileRow.profile) controld.selectProfile(profileRow.profile.id)
    }

    PanelToolTip {
      visible: profileMouse.containsMouse && !profileRow.selectedProfile
      text: "Show this profile's rules"
      fontFamily: root.fontFamily
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

  component InfoLabel: Text {
    color: root.foreground
    opacity: 0.6
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component InfoValue: Text {
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component DetailValue: InfoValue {
    id: detailValue
    property bool copyable: false
    property string tooltipText: "Copy to clipboard"

    Layout.fillWidth: true
    horizontalAlignment: Text.AlignRight
    // Reserve the glyph's width whether or not it is showing, so the value
    // does not shift sideways under the pointer.
    rightPadding: copyable ? copyGlyph.width + Style.space(4) : 0

    Text {
      id: copyGlyph
      visible: detailValue.copyable && detailValue.text !== ""
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: "󰆏"
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
      enabled: detailValue.copyable && detailValue.text !== ""
      hoverEnabled: enabled
      cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: controld.copyToClipboard(detailValue.text)
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
        width: meterList.width
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
    property int hits: 0
    property real ratio: 0

    implicitHeight: rowLabel.implicitHeight + Style.spacing.sm * 2

    readonly property bool interactive: copyValue !== ""
    readonly property bool hot: interactive && rowMouse.containsMouse

    Text {
      id: rowLabel
      anchors.left: parent.left
      anchors.right: meterTrack.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      text: meterRow.label
      color: meterRow.hot ? root.foreground : Qt.darker(root.foreground, 1.25)
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideMiddle
    }

    Rectangle {
      id: meterTrack
      anchors.right: rowValue.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width * 0.28
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
      font.pixelSize: Style.font.bodySmall
    }

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      enabled: meterRow.interactive
      hoverEnabled: enabled
      cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: controld.copyToClipboard(meterRow.copyValue)
    }

    PanelToolTip {
      visible: meterRow.hot
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
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }

    Button {
      text: "Open setup guide"
      bordered: true
      foreground: root.foreground
      accent: Color.accent
      fontFamily: root.fontFamily
      fontSize: Style.font.bodySmall
      topPadding: Style.space(4)
      onClicked: Quickshell.execDetached(["omarchy-launch-browser", root.guideUrl])
    }
  }

  // One lookup: what was asked, what happened to it, and when. The A/AAAA
  // pair of a single lookup arrives already collapsed.
  component ActivityRow: Item {
    id: activityRow
    property var query: null
    readonly property string question: query ? query.question : ""
    readonly property bool blocked: query && query.action === 0

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
          color: activityMouse.containsMouse ? root.foreground : Qt.darker(root.foreground, 1.25)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
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

    hasCursor: root.cursorActive && root.focusSection === "rules" && root.ruleIndex === rowIndex
    foreground: root.foreground
    fill: root.hoverFill

    implicitHeight: ruleContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      id: ruleMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.setRuleCursor(ruleRow.rowIndex)
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
