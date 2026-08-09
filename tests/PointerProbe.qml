import QtQuick
import Quickshell
import Quickshell.Wayland

ShellRoot {
    PanelWindow {
        id: probeWindow

        property bool armed: false

        visible: true
        color: "transparent"
        WlrLayershell.namespace: "mihomo-widget:pointer-probe"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.exclusiveZone: -1
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        mask: Region {
            item: probeArea
        }

        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }

        Timer {
            interval: 900
            running: true
            onTriggered: {
                console.warn("POINTER_PROBE_WINDOW", probeWindow.width, probeWindow.height);
                probeWindow.armed = true;
            }
        }

        Timer {
            interval: 3500
            running: true
            onTriggered: Qt.quit()
        }

        MouseArea {
            id: probeArea
            anchors.fill: parent
            hoverEnabled: true
            onPositionChanged: mouse => {
                if (probeWindow.armed)
                    console.warn("POINTER_PROBE", Math.round(mouse.x), Math.round(mouse.y));
            }
        }
    }
}
