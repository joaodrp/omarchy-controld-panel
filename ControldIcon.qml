import QtQuick
import QtQuick.Shapes
import qs.Commons
import qs.Ui

// The Control D mark rendered natively from its SVG paths (a 42x38 viewBox),
// tinted to the theme like the built-in Tailscale and Dropbox marks. Native
// paths stay crisp at bar sizes where a rasterized SVG goes soft.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground
  property color badgeColor: Color.urgent
  property bool crossed: false
  property bool warning: false

  readonly property real viewWidth: 42
  readonly property real viewHeight: 38
  readonly property real markScale: iconSize / viewWidth

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  Shape {
    width: root.viewWidth
    height: root.viewHeight
    x: (root.width - root.viewWidth * root.markScale) / 2
    y: (root.height - root.viewHeight * root.markScale) / 2
    transformOrigin: Item.TopLeft
    scale: root.markScale
    antialiasing: true
    layer.enabled: true
    layer.samples: 4
    preferredRendererType: Shape.CurveRenderer

    Blade { path: "M2.59817 16C1.73199 16 1.03883 15.2655 1.18488 14.4118C2.39502 7.338 8.52232 2 16.2388 2H19.3786C20.0414 2 20.5786 2.53726 20.5786 3.2C20.5786 10.2692 14.8479 16 7.77861 16H2.59817Z" }
    Blade { path: "M2.43556 17.9426C1.56751 17.9398 0.871345 18.6752 1.02014 19.5304C2.25182 26.6097 8.52372 32 16.2388 32H19.3751C20.0398 32 20.5786 31.4612 20.5786 30.7965C20.5786 23.7227 14.856 17.9819 7.78215 17.9595L2.43556 17.9426Z" }
    Blade { path: "M35.3868 18C28.3175 18 22.5868 23.7308 22.5868 30.8C22.5868 31.4627 23.124 32 23.7868 32H26.9273C34.6437 32 40.7705 26.662 41.9805 19.5882C42.1266 18.7345 41.4334 18 40.5672 18H35.3868Z" }
    Blade { path: "M40.5672 16C41.4334 16 42.1266 15.2655 41.9805 14.4118C40.7705 7.338 34.6437 2 26.9273 2H23.7135C23.0444 2 22.5031 2.54462 22.5073 3.21371C22.5513 10.2882 28.2987 16 35.3733 16H40.5672Z" }
  }

  component Blade: ShapePath {
    property alias path: svg.path
    fillColor: root.color
    strokeWidth: 0
    strokeColor: "transparent"
    PathSvg { id: svg }
  }

  Rectangle {
    visible: root.crossed
    anchors.centerIn: parent
    width: parent.width * 1.22
    height: Math.max(2, parent.height * 0.14)
    radius: height / 2
    color: root.color
    rotation: -45
  }

  BorderSurface {
    visible: root.warning
    width: Math.max(7, parent.width * 0.42)
    height: width
    radius: width / 2
    color: root.badgeColor
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    borderSpec: Border.flat(Color.popups.background, 1)

    Text {
      anchors.centerIn: parent
      text: "!"
      color: Color.background
      font.family: Style.font.family
      font.pixelSize: Math.max(6, parent.height * 0.72)
      font.bold: true
    }
  }
}
