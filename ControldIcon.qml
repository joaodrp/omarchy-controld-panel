import QtQuick
import QtQuick.Shapes
import qs.Commons
import qs.Ui

// The Control D mark rendered natively from its SVG paths (a 42x38 viewBox),
// tinted to the theme like the built-in Tailscale and Dropbox marks. Native
// paths stay crisp at bar sizes where a rasterized SVG goes soft.
Item {
  id: root

  // The mark's painted height, which is what lines it up with its neighbours.
  // Width follows the mark's own aspect: it is a wide silhouette, not a square.
  property real iconSize: Style.font.icon
  property color color: Color.foreground
  property color badgeColor: Color.urgent
  property bool crossed: false
  property bool warning: false

  readonly property real viewWidth: 42
  readonly property real viewHeight: 38
  // The blades ink only x 1..42 and y 2..32 of that viewBox, and the slack is
  // uneven: 2 above the mark, 6 below. Both the scale and the offset therefore
  // come from the ink box. The viewBox would scale the mark to 71% of the
  // height asked for and sit it 5% too high.
  readonly property real inkX: 1
  readonly property real inkY: 2
  readonly property real inkWidth: 41
  readonly property real inkHeight: 30
  readonly property real markScale: iconSize / inkHeight

  width: inkWidth * markScale
  height: iconSize
  implicitWidth: width
  implicitHeight: height

  Shape {
    width: root.viewWidth
    height: root.viewHeight
    // The item is the ink box, so the viewBox hangs off it by its own margins.
    x: -root.inkX * root.markScale
    y: -root.inkY * root.markScale
    transformOrigin: Item.TopLeft
    scale: root.markScale
    antialiasing: true
    // No layer: caching the mark at its 42x38 path size and then scaling that
    // texture down to bar size throws the antialiasing away. The curve
    // renderer rasterizes after the transform, so the edges stay smooth at
    // whatever size the mark is drawn.
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

  // A bare dot: at bar size the ring leaves too little room for a glyph, and a
  // "!" collapses into a bar there. Sized off the mark's height rather than its
  // width, so the badge tracks the mark's optical size and not its silhouette.
  // The floor is what stays legible in the bar, and it carries that size alone
  // until the mark is large enough for the proportion to take over.
  BorderSurface {
    visible: root.warning
    width: Math.max(6, parent.height * 0.4)
    height: width
    radius: width / 2
    color: root.badgeColor
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    borderSpec: Border.flat(Color.popups.background, 1)
  }
}
