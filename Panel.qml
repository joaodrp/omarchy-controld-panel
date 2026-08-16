import QtQuick
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

  readonly property bool showProfiles: controld.ready && controld.profiles.length > 0
  readonly property bool showRules: controld.ready && controld.selectedProfile !== null
  // Only rule rows take the cursor; folder headers are labels.
  readonly property var cursorRules: cursorRuleList()
  readonly property bool headerHasCursor: cursorActive && focusSection === "header" && controld.installed
  readonly property color iconColor: controld.ready ? foreground : dim
  readonly property color barIconColor: controld.ready ? barForeground : Qt.darker(barForeground, 1.55)
  readonly property string heroTitle: controld.selectedProfile ? controld.selectedProfile.name : "Control D"
  readonly property string heroMeta: {
    if (!controld.installed) return "cdctl is not installed"
    if (controld.needsAuth) return "Not authenticated"
    if (controld.refreshing && !controld.authenticated) return "Checking…"
    return controld.statusText
  }
  readonly property string rulesCaption: {
    if (controld.loadingRules && controld.rules.length === 0) return "Loading rules…"
    var c = controld.ruleCount
    if (c.total === 0) return "No custom rules in this profile."
    return c.enabled + " of " + c.total + " enabled"
  }

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

  onOpenedChanged: if (opened) {
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
          crossed: controld.checkedInstall && !controld.installed
          warning: controld.installed && controld.needsAuth
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) controld.selectNextProfile(1)
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
        if (t === "r" || t === "R") controld.refresh()
        else if (t === "p" || t === "P") controld.selectNextProfile(1)
        else if (t === "c" || t === "C") controld.copyToClipboard(root.selectedRule() ? root.selectedRule().hostname : "")
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
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
                  crossed: controld.checkedInstall && !controld.installed
                  warning: controld.installed && controld.needsAuth
                }
              }

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
            visible: controld.lastHint !== ""
            width: parent.width
            text: controld.lastHint
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          CursorSurface {
            visible: controld.checkedInstall && !controld.installed
            width: parent.width
            implicitHeight: missingText.implicitHeight + Style.spacing.rowPaddingX
            foreground: root.foreground

            Text {
              id: missingText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(12)
              text: "cdctl is not installed or not on PATH."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
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

            PanelSectionHeader {
              text: "PROFILES"
              foreground: root.foreground
              fontFamily: root.fontFamily
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
            visible: root.showRules
            foreground: root.foreground
          }

          Column {
            visible: root.showRules
            width: parent.width
            spacing: Style.space(10)

            RowLayout {
              width: parent.width
              spacing: Style.space(8)

              PanelSectionHeader {
                text: "RULES"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Item { Layout.fillWidth: true }

              Text {
                text: root.rulesCaption
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                Layout.maximumWidth: parent.width * 0.6
              }
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
    }
  }

  // Position of a rule among rule rows only, given its index in ruleRows.
  function ruleOrdinal(rowsIndex) {
    var rows = controld.ruleRows
    var n = 0
    for (var i = 0; i < rowsIndex && i < rows.length; i++) if (rows[i].kind === "rule") n++
    return n
  }

  component ProfileRow: CursorSurface {
    id: profileRow
    property var profile: null
    property int rowIndex: 0
    readonly property bool selectedProfile: profile && controld.selectedProfile && controld.selectedProfile.id === profile.id
    readonly property bool loading: selectedProfile && controld.loadingRules

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

      Text {
        text: profileRow.profile && !profileRow.profile.enabled ? "󰚌" : "󰒃"
        color: profileRow.selectedProfile ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        width: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter
        opacity: profileRow.loading ? 0.45 : 1.0

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

        Text {
          width: parent.width
          text: profileRow.profile ? profileRow.profile.name : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: profileRow.selectedProfile
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          text: Model.profileDetail(profileRow.profile)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
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
