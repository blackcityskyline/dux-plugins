import QtQuick
import Quickshell

ShellRoot {
    FloatingWindow {
        id: probeWindow

        visible: true
        maximized: true
        title: "Mihomo input shield probe"
        color: "#11161d"

        Rectangle {
            anchors.fill: parent
            color: "#11161d"

            Column {
                anchors.centerIn: parent
                width: Math.min(parent.width - 80, 680)
                spacing: 12

                Text {
                    width: parent.width
                    text: "Mihomo input shield test"
                    color: "#f2f5f8"
                    font.pixelSize: 28
                    horizontalAlignment: Text.AlignHCenter
                }

                Text {
                    width: parent.width
                    text: "The DMS bar and Mihomo popout must remain visible above this window. Any click or wheel event reaching this window is reported as a leak."
                    color: "#aeb8c4"
                    font.pixelSize: 16
                    wrapMode: Text.WordWrap
                    horizontalAlignment: Text.AlignHCenter
                }
            }

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                onPressed: mouse => console.warn("MIHOMO_INPUT_LEAK", "press", Math.round(mouse.x), Math.round(mouse.y))
                onWheel: wheel => console.warn("MIHOMO_INPUT_LEAK", "wheel", Math.round(wheel.angleDelta.x), Math.round(wheel.angleDelta.y))
            }
        }

        Component.onCompleted: console.warn("MIHOMO_INPUT_PROBE_READY")
    }
}
