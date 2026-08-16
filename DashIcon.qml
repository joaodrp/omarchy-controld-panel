import QtQuick
import QtQuick.Effects
import qs.Commons

// Control D dashboard icons (assets/*.svg), tinted to the theme. The marks
// ship as single-color silhouettes, so one file serves every Omarchy theme.
Item {
  id: root

  // Basename under assets/, without the extension: profiles, endpoints,
  // analytics, statistics, activity, domain-test, preferences.
  property string name: ""
  property real iconSize: Style.font.icon
  property color color: Color.foreground

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  Image {
    id: mark
    anchors.fill: parent
    source: root.name === "" ? "" : Qt.resolvedUrl("assets/" + root.name + ".svg")
    // Rasterize above the drawn size so the mark stays sharp when the bar or
    // the panel scales it up.
    sourceSize.width: Math.ceil(root.iconSize * 2)
    sourceSize.height: Math.ceil(root.iconSize * 2)
    fillMode: Image.PreserveAspectFit
    smooth: true
    visible: false
  }

  MultiEffect {
    anchors.fill: parent
    source: mark
    colorization: 1.0
    colorizationColor: root.color
    visible: mark.status === Image.Ready
  }
}
