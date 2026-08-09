import QtQuick
import Quickshell
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: "mihomoVpn"
    property var availableGroups: []
    property var selectedGroups: []
    property string apiError: ""
    property bool loadingGroups: false
    property bool needsInitialSelection: false

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
    function move(name, delta) {
        let next = selectedGroups.slice();
        const at = next.indexOf(name), target = at + delta;
        if (at < 0 || target < 0 || target >= next.length) return;
        const item = next.splice(at, 1)[0]; next.splice(target, 0, item);
        selectedGroups = next; saveGroups();
    }
    Component.onCompleted: loadGroups()

    Connections {
        target: root
        function onPluginServiceChanged() {
            if (root.pluginService)
                root.loadSavedGroups();
        }
    }

    StyledText { width: parent.width; text: "Mihomo groups"; font.pixelSize: Theme.fontSizeLarge; font.weight: Font.Bold; color: Theme.surfaceText }
    StyledText { width: parent.width; text: "Choose Selector groups for the widget and arrange their order. Every selected group appears in the plugin popout."; wrapMode: Text.WordWrap; color: Theme.surfaceVariantText; font.pixelSize: Theme.fontSizeSmall }

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
    Repeater { model: root.availableGroups
        delegate: Rectangle { width: parent.width; height: 36; radius: Theme.cornerRadius; color: root.selectedGroups.indexOf(modelData.name) >= 0 ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh
            StyledText { anchors.left: parent.left; anchors.leftMargin: Theme.spacingM; anchors.verticalCenter: parent.verticalCenter; text: (root.selectedGroups.indexOf(modelData.name) >= 0 ? "✓  " : "○  ") + modelData.name; color: Theme.surfaceText }
            StyledText { anchors.right: up.left; anchors.rightMargin: Theme.spacingS; anchors.verticalCenter: parent.verticalCenter; text: modelData.type; color: Theme.surfaceVariantText; font.pixelSize: Theme.fontSizeSmall }
            DankIcon { id: up; anchors.right: down.left; anchors.rightMargin: Theme.spacingS; anchors.verticalCenter: parent.verticalCenter; name: "keyboard_arrow_up"; size: 17; color: Theme.primary; visible: root.selectedGroups.indexOf(modelData.name) > 0 }
            DankIcon { id: down; anchors.right: parent.right; anchors.rightMargin: Theme.spacingM; anchors.verticalCenter: parent.verticalCenter; name: "keyboard_arrow_down"; size: 17; color: Theme.primary; visible: root.selectedGroups.indexOf(modelData.name) >= 0 && root.selectedGroups.indexOf(modelData.name) < root.selectedGroups.length - 1 }
            MouseArea { anchors.fill: parent; onClicked: mouse => {
                const position = root.selectedGroups.indexOf(modelData.name);
                if (position >= 0 && mouse.x > parent.width - 64) {
                    root.move(modelData.name, mouse.x > parent.width - 32 ? 1 : -1);
                } else {
                    root.toggleGroup(modelData.name);
                }
            } }
        }
    }
}
