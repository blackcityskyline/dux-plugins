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
    property string draggingGroup: ""
    property var previewGroups: []
    readonly property var orderedGroupNames: (draggingGroup ? previewGroups : selectedGroups).concat(
        availableGroups.map(group => group.name).filter(name => selectedGroups.indexOf(name) < 0))
    readonly property int groupRowStep: 36 + Theme.spacingS

    readonly property string helper: Paths.strip(Qt.resolvedUrl("mihomo-dms"))

    function loadSavedGroups() {
        cancelDrag();
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

    function beginDrag(name) {
        if (selectedGroups.indexOf(name) < 0)
            return;
        previewGroups = selectedGroups.slice();
        draggingGroup = name;
    }

    function updateDragTarget(centerY) {
        if (!draggingGroup)
            return;
        // Same center/slot threshold as DMS WidgetsTabSection.slotIndexForY.
        const target = Math.max(0, Math.min(selectedGroups.length - 1,
            Math.floor((centerY + groupRowStep / 2) / groupRowStep)));
        const next = previewGroups.slice();
        const from = next.indexOf(draggingGroup);
        if (from < 0 || from === target)
            return;
        next.splice(from, 1);
        next.splice(target, 0, draggingGroup);
        previewGroups = next;
    }

    function commitDrag() {
        if (draggingGroup)
            moveTo(draggingGroup, previewGroups.indexOf(draggingGroup));
        cancelDrag();
    }

    function cancelDrag() {
        draggingGroup = "";
        previewGroups = [];
    }

    onAvailableGroupsChanged: cancelDrag()
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
        description: "Enable VPN once after this widget loads, when the Mihomo API is available. Does not start the Mihomo service."
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
                readonly property bool dragging: root.draggingGroup === modelData.name
                width: groupsList.width
                height: 36
                z: dragging ? 100 : 0

                Binding {
                    target: groupSlot
                    property: "y"
                    value: root.orderedGroupNames.indexOf(groupSlot.modelData.name) * root.groupRowStep
                    when: !groupSlot.dragging
                    restoreMode: Binding.RestoreNone
                }

                onYChanged: {
                    if (dragging)
                        root.updateDragTarget(y + height / 2);
                }

                // Match DMS's widget-section reorder motion, including its
                // spatial overshoot. The held row follows the pointer directly.
                Behavior on y {
                    enabled: !groupSlot.dragging
                    NumberAnimation {
                        duration: Theme.expressiveDurations.expressiveDefaultSpatial
                        easing.type: Easing.BezierSpline
                        easing.bezierCurve: Theme.expressiveCurves.expressiveFastSpatial
                    }
                }

                Rectangle {
                    id: groupRow
                    objectName: "settingsGroup:" + groupSlot.modelData.name
                    width: parent.width
                    height: parent.height
                    scale: groupSlot.dragging ? 1.02 : 1.0
                    radius: groupSlot.dragging ? Theme.cornerRadius + 6 : Theme.cornerRadius
                    color: groupSlot.dragging ? Theme.secondaryContainer
                        : (groupSlot.selected ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh)
                    border.width: groupSlot.dragging ? 2 : 0
                    border.color: Theme.primary

                    Behavior on scale {
                        NumberAnimation { duration: Theme.shortDuration; easing.type: Easing.OutCubic }
                    }
                    Behavior on radius {
                        NumberAnimation { duration: Theme.shortDuration; easing.type: Easing.OutCubic }
                    }
                    Behavior on color {
                        ColorAnimation { duration: Theme.shortDuration }
                    }

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
                        cursorShape: groupSlot.dragging ? Qt.ClosedHandCursor : (groupSlot.selected ? Qt.OpenHandCursor : Qt.PointingHandCursor)
                        drag.target: groupSlot.selected ? groupSlot : null
                        drag.axis: Drag.YAxis
                        drag.minimumY: 0
                        drag.maximumY: (root.selectedGroups.length - 1) * root.groupRowStep
                        drag.smoothed: false
                        preventStealing: groupSlot.selected
                        onPressed: root.beginDrag(groupSlot.modelData.name)
                        onReleased: {
                            if (drag.active)
                                root.commitDrag();
                            else
                                root.cancelDrag();
                        }
                        onCanceled: root.cancelDrag()
                        onClicked: root.toggleGroup(groupSlot.modelData.name)
                    }
                }
            }
        }
    }
}
