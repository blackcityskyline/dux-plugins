import QtQuick
import Quickshell
import qs.Common
import qs.Widgets
import qs.Modules.Plugins
import "UiText.js" as UiText

PluginSettings {
    id: root
    pluginId: "mihomoVpn"
    property var availableGroups: []
    property var selectedGroups: []
    property string apiError: ""
    property bool loadingGroups: false
    property bool needsInitialSelection: false
    readonly property var orderedGroupNames: selectedGroups.concat(
        availableGroups.map(group => group.name).filter(name => selectedGroups.indexOf(name) < 0))
    readonly property int groupRowStep: 36 + Theme.spacingS

    readonly property string helper: Paths.strip(Qt.resolvedUrl("mihomo-dms"))

    function loadSavedGroups() {
        const savedGroups = loadValue("visibleGroups", null);
        needsInitialSelection = !Array.isArray(savedGroups);
        selectedGroups = Array.isArray(savedGroups) ? savedGroups.slice() : [];
        reconcileSelection();
    }

    function reconcileSelection() {
        if (availableGroups.length === 0)
            return;
        if (needsInitialSelection) {
            selectedGroups = availableGroups.slice(0, 2).map(group => group.name);
            needsInitialSelection = false;
            saveGroups();
            return;
        }
        const allowedNames = availableGroups.map(group => group.name);
        const validSelection = selectedGroups.filter(name => allowedNames.indexOf(name) >= 0);
        if (validSelection.length !== selectedGroups.length) {
            selectedGroups = validSelection;
            saveGroups();
        }
    }

    function loadGroups() {
        if (loadingGroups)
            return;
        apiError = "";
        loadingGroups = true;
        Proc.runCommand("mihomoVpn.settings.groups", [helper, "groups"], (output, exitCode) => {
            loadingGroups = false;
            if (exitCode !== 0) {
                availableGroups = [];
                apiError = "Mihomo API is unavailable. Check mihomo.service and 127.0.0.1:9090.";
                return;
            }
            try {
                const groups = JSON.parse(output);
                if (!Array.isArray(groups))
                    throw new Error("Unexpected groups response");
                availableGroups = groups.filter(group => group && group.type === "Selector");
                if (!availableGroups.length)
                    apiError = "Mihomo API returned no Selector groups.";
                reconcileSelection();
            } catch (error) {
                availableGroups = [];
                apiError = "Mihomo API returned an invalid response.";
            }
        }, 0, 5000);
    }
    function saveGroups() {
        saveValue("visibleGroups", selectedGroups);
    }
    function toggleGroup(name) {
        let next = selectedGroups.slice();
        const at = next.indexOf(name);
        at >= 0 ? next.splice(at, 1) : next.push(name);
        selectedGroups = next;
        saveGroups();
    }
    function moveTo(name, target) {
        let next = selectedGroups.slice();
        const at = next.indexOf(name);
        if (at < 0 || target < 0 || target >= next.length || at === target) return;
        const item = next.splice(at, 1)[0]; next.splice(target, 0, item);
        selectedGroups = next; saveGroups();
    }
    Component.onCompleted: {
        if (pluginService)
            loadSavedGroups();
        loadGroups();
    }

    Connections {
        target: root
        function onPluginServiceChanged() {
            if (root.pluginService)
                root.loadSavedGroups();
        }
    }

    ToggleSetting {
        settingKey: "enableVpnOnStartup"
        label: "Enable VPN on startup"
        description: "Turn VPN on when this widget loads, including after a shell restart or plugin reload."
        defaultValue: false
    }

    StyledText { width: parent.width; text: "Mihomo groups"; font.pixelSize: Theme.fontSizeLarge; font.weight: Font.Bold; color: Theme.surfaceText }
    StyledText { width: parent.width; text: "Click to enable or disable groups. Drag enabled groups to change their order in the widget. Disabled groups appear below."; wrapMode: Text.WordWrap; color: Theme.surfaceVariantText; font.pixelSize: Theme.fontSizeSmall }

    Rectangle { width: parent.width; height: 34; radius: Theme.cornerRadius; color: Theme.surfaceContainerHigh
        StyledText { anchors.left: parent.left; anchors.leftMargin: Theme.spacingM; anchors.right: groupsRefreshIcon.left; anchors.rightMargin: Theme.spacingS; anchors.verticalCenter: parent.verticalCenter; text: root.loadingGroups ? "Loading groups from the Mihomo API…" : (apiError || "Available groups"); color: apiError ? Theme.error : Theme.surfaceText; elide: Text.ElideRight }
        DankIcon {
            id: groupsRefreshIcon
            anchors.right: parent.right
            anchors.rightMargin: Theme.spacingM
            anchors.verticalCenter: parent.verticalCenter
            name: "refresh"
            size: 18
            color: Theme.primary
            smoothTransform: root.loadingGroups
            RotationAnimator on rotation {
                from: 0
                to: 360
                duration: 1000
                loops: Animation.Infinite
                running: root.loadingGroups
                onRunningChanged: {
                    if (!running)
                        groupsRefreshIcon.rotation = 0;
                }
            }
        }
        MouseArea { anchors.fill: parent; enabled: !root.loadingGroups; onClicked: root.loadGroups() }
    }
    Item {
        id: groupsList
        width: parent.width
        height: Math.max(0, root.availableGroups.length * root.groupRowStep - Theme.spacingS)

        // Keep delegates stable while selectedGroups changes. Only their
        // positions change, so moving a row never destroys its pointer grab.
        Repeater {
            model: root.availableGroups
            delegate: Item {
                id: groupSlot
                required property var modelData
                readonly property bool selected: root.selectedGroups.indexOf(modelData.name) >= 0
                width: groupsList.width
                height: 36
                y: root.orderedGroupNames.indexOf(modelData.name) * root.groupRowStep
                z: groupMouse.drag.active ? 1 : 0

                Rectangle {
                    id: groupRow
                    objectName: "settingsGroup:" + groupSlot.modelData.name
                    width: parent.width
                    height: parent.height
                    radius: Theme.cornerRadius
                    color: groupSlot.selected ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh
                    border.width: groupMouse.drag.active ? 1 : 0
                    border.color: Theme.primary

                    StyledText {
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.spacingM
                        anchors.right: groupType.left
                        anchors.rightMargin: Theme.spacingS
                        anchors.verticalCenter: parent.verticalCenter
                        text: (groupSlot.selected ? "✓  " : "○  ") + UiText.displayName(groupSlot.modelData.name)
                        color: Theme.surfaceText
                        elide: Text.ElideRight
                    }
                    StyledText {
                        id: groupType
                        anchors.right: dragHandle.left
                        anchors.rightMargin: Theme.spacingS
                        anchors.verticalCenter: parent.verticalCenter
                        text: groupSlot.modelData.type
                        color: Theme.surfaceVariantText
                        font.pixelSize: Theme.fontSizeSmall
                    }
                    DankIcon {
                        id: dragHandle
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.spacingM
                        anchors.verticalCenter: parent.verticalCenter
                        name: "drag_indicator"
                        size: 17
                        color: Theme.surfaceVariantText
                        visible: groupSlot.selected
                    }
                    MouseArea {
                        id: groupMouse
                        anchors.fill: parent
                        cursorShape: drag.active ? Qt.ClosedHandCursor : (groupSlot.selected ? Qt.OpenHandCursor : Qt.PointingHandCursor)
                        drag.target: groupSlot.selected ? groupRow : null
                        drag.axis: Drag.YAxis
                        drag.minimumY: -groupSlot.y
                        drag.maximumY: (root.selectedGroups.length - 1) * root.groupRowStep - groupSlot.y
                        onReleased: {
                            if (drag.active) {
                                const target = Math.round((groupSlot.y + groupRow.y) / root.groupRowStep);
                                groupRow.y = 0;
                                root.moveTo(groupSlot.modelData.name, target);
                            }
                        }
                        onCanceled: groupRow.y = 0
                        onClicked: root.toggleGroup(groupSlot.modelData.name)
                    }
                }
            }
        }
    }
}
