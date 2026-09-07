import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins
import "UiText.js" as UiText

PluginComponent {
    id: root

    property bool active: false
    property bool available: false
    property bool toggling: false
    property bool startupHandled: false
    property bool pinging: false
    property string serviceError: ""
    readonly property string controlError: serviceError || (!available ? "Mihomo is unavailable. Use the VPN switch to start the service." : "")
    property bool updatingSubscription: false
    property var subscriptionStatus: null
    readonly property string subscriptionError: UiText.subscriptionError(subscriptionStatus)
    readonly property bool subscriptionBusy: updatingSubscription || (subscriptionStatus && subscriptionStatus.phase === "updating")
    readonly property string visibleSubscriptionError: subscriptionBusy ? "" : subscriptionError
    readonly property string indicatorError: visibleSubscriptionError || controlError
    readonly property string subscriptionTooltip: subscriptionBusy ? "Updating subscription…" : (subscriptionError ? "Retry subscription update" : "Update subscription")
    property var groupStates: []
    property var displayedGroups: []
    property var expandedGroups: ({})
    property string pingText: ""
    property var stats: []
    property int refreshGeneration: 0
    property var popoutTarget: null

    readonly property string helper: Paths.strip(Qt.resolvedUrl("mihomo-dms"))
    readonly property url dashboardUrl: "http://127.0.0.1:9090/ui/"
    readonly property int groupBaseHeight: 68
    readonly property int choiceRowHeight: 30
    readonly property int listSeparatorHeight: 1
    readonly property int emptyStateHeight: 44
    readonly property int popoutHeaderHeight: 40
    readonly property var configuredGroups: {
        const groups = pluginData.visibleGroups;
        if (!Array.isArray(groups))
            return [];
        return groups.filter(group => typeof group === "string" && group.length > 0);
    }
    readonly property string label: {
        if (!active)
            return "OFF";
        if (groupStates.length > 0) {
            const first = groupStates[0];
            return UiText.displayName(first.shownCurrent || first.current || first.name || "ON");
        }
        return "ON";
    }
    readonly property int collapsedGroupsHeight: displayedGroups.length > 0 ? displayedGroups.length * groupBaseHeight + Math.max(0, displayedGroups.length - 1) * Theme.spacingS : 0
    readonly property int expandedHeight: {
        let height = 0;
        for (let i = 0; i < displayedGroups.length; i++)
            height += groupExpandedHeight(displayedGroups[i]);
        return height;
    }
    readonly property int groupsContentHeight: displayedGroups.length > 0 ? collapsedGroupsHeight + expandedHeight : emptyStateHeight
    readonly property int maximumGroupsViewportHeight: {
        const screenHeight = parentScreen && parentScreen.height > 0 ? parentScreen.height : 1080;
        const barReserve = Math.max(barThickness + barSpacing, Theme.barHeight + Theme.spacingS);
        const chromeReserve = popoutHeaderHeight + Theme.spacingS * 2 + Theme.spacingL * 2;
        return Math.max(180, Math.floor(screenHeight - barReserve - chromeReserve));
    }
    readonly property int groupsViewportHeight: Math.min(groupsContentHeight, maximumGroupsViewportHeight)

    onConfiguredGroupsChanged: {
        refreshGeneration++;
        expandedGroups = ({});
        groupStates = [];
        displayedGroups = [];
        stats = [];
        refresh();
    }

    function showInfo(title, message) {
        if (typeof ToastService !== "undefined")
            ToastService.showInfo(title, message);
    }

    function sameStringArray(left, right) {
        if (!Array.isArray(left) || !Array.isArray(right) || left.length !== right.length)
            return false;
        for (let i = 0; i < left.length; i++) {
            if (left[i] !== right[i])
                return false;
        }
        return true;
    }

    function sameData(left, right) {
        return JSON.stringify(left) === JSON.stringify(right);
    }

    function applyGroupStates(groups) {
        const nextGroups = Array.isArray(groups) ? groups : [];
        const nextNames = nextGroups.map(group => group.name);
        if (!sameData(groupStates, nextGroups))
            groupStates = nextGroups;
        if (!sameStringArray(displayedGroups, nextNames))
            displayedGroups = nextNames;
    }

    function applyStats(nextStats) {
        const normalized = Array.isArray(nextStats) ? nextStats : [];
        if (!sameData(stats, normalized))
            stats = normalized;
    }

    function refresh() {
        refreshSubscriptionStatus();
        const requestedGroups = configuredGroups.slice();
        const requestKey = JSON.stringify(requestedGroups);
        const generation = ++refreshGeneration;
        Proc.runCommand("mihomoVpn.status", [helper, "status"].concat(requestedGroups), (output, exitCode) => {
            if (generation !== refreshGeneration || requestKey !== JSON.stringify(configuredGroups))
                return;
            if (exitCode !== 0) {
                markControllerUnavailable();
                return;
            }
            try {
                const data = JSON.parse(output);
                available = true;
                active = data.active === true;
                applyGroupStates(data.groups);
                applyStats(data.stats);
            } catch (error) {
                markControllerUnavailable();
            }
        }, 0, 5000);
    }

    function markControllerUnavailable() {
        available = false;
        // A stopped or unreachable controller cannot provide VPN routing.
        // Do not leave a stale enabled indicator in the bar.
        active = false;
    }

    function applyControlResult(output, exitCode, successMessage) {
        let result = null;
        try {
            result = JSON.parse(output);
        } catch (error) {}
        if (exitCode === 0 && result && result.ok === true) {
            serviceError = "";
            active = result.active === true;
            available = result.available === true;
            showInfo("Mihomo VPN", successMessage);
        } else {
            serviceError = UiText.englishError(result && result.error, "Could not control Mihomo. Check the local controller.");
            if (typeof ToastService !== "undefined")
                ToastService.showError("Mihomo VPN", serviceError);
        }
    }

    function applySubscriptionStatus(data) {
        if (data && typeof data.phase === "string")
            subscriptionStatus = data;
        else
            subscriptionStatus = {
                phase: "error",
                error: "Could not read the subscription update status."
            };
    }

    function refreshSubscriptionStatus() {
        Proc.runCommand("mihomoVpn.subscriptionStatus", [helper, "subscription-status"], (output, exitCode) => {
            try {
                applySubscriptionStatus(JSON.parse(output));
            } catch (error) {
                applySubscriptionStatus(null);
            }
        }, 0, 5000);
    }

    function updateSubscription() {
        if (subscriptionBusy)
            return;
        updatingSubscription = true;
        Proc.runCommand("mihomoVpn.updateSubscription", [helper, "refresh-subscription"], (output, exitCode) => {
            updatingSubscription = false;
            try {
                applySubscriptionStatus(JSON.parse(output));
            } catch (error) {
                applySubscriptionStatus({
                    phase: "error",
                    error: "Subscription update failed. Check the updater service."
                });
            }
            if (exitCode !== 0 && !subscriptionError)
                applySubscriptionStatus({
                    phase: "error",
                    error: "Subscription update failed. Please try again."
                });
            if (subscriptionError && typeof ToastService !== "undefined")
                ToastService.showError("Capybara subscription update failed", subscriptionError);
            else
                showInfo("Capybara", "Subscription updated successfully");
            refresh();
        }, 0, 70000);
    }

    function toggleVpn() {
        setVpnEnabled(!active);
    }

    function applyStartupPreference() {
        if (startupHandled)
            return;
        startupHandled = true;
        if (pluginData.enableVpnOnStartup === true)
            setVpnEnabled(true);
    }

    function setVpnEnabled(enabled) {
        if (toggling)
            return;
        const requestedState = enabled ? "on" : "off";
        toggling = true;
        Proc.runCommand("mihomoVpn.setVpn", [helper, "set-vpn", requestedState], (output, exitCode) => {
            toggling = false;
            applyControlResult(output, exitCode, requestedState === "on" ? "VPN enabled" : "VPN disabled: direct connection");
            refresh();
        }, 0, 50000);
    }

    function select(group, target) {
        if (!target)
            return;
        Proc.runCommand("mihomoVpn.select." + group, [helper, "select", group, target], (output, exitCode) => {
            showInfo("Mihomo VPN", exitCode === 0 ? (UiText.displayName(group) + ": " + UiText.displayName(target)) : ("Failed to switch " + UiText.displayName(group)));
            refresh();
            // Mihomo applies the PUT synchronously in practice, but a short
            // second read keeps the status correct on a busy/reconnecting core.
            selectionRefreshTimer.restart();
        }, 0, 7000);
    }

    function pingAll() {
        if (pinging)
            return;
        pinging = true;
        pingText = "Checking all nodes…";
        Proc.runCommand("mihomoVpn.pingAll", [helper, "ping-all"].concat(configuredGroups), (output, exitCode) => {
            pinging = false;
            if (exitCode === 0) {
                try {
                    const result = JSON.parse(output);
                    const reachable = result.results.filter(item => item.delay >= 0).length;
                    pingText = "Checked: " + reachable + " / " + result.results.length;
                } catch (error) {
                    pingText = "Check complete";
                }
                refresh();
            } else {
                pingText = "Node check failed";
            }
        }, 0, 45000);
    }

    function toggleGroup(group) {
        const next = Object.assign({}, expandedGroups);
        if (next[group] === true)
            delete next[group];
        else
            next[group] = true;
        expandedGroups = next;
    }

    function groupState(name) {
        for (let i = 0; i < groupStates.length; i++) {
            if (groupStates[i].name === name)
                return groupStates[i];
        }
        return {
            name: name,
            type: "",
            current: "",
            shownCurrent: "",
            choices: []
        };
    }

    function additionalChoices(group) {
        const state = groupState(group);
        const choices = Array.isArray(state.choices) ? state.choices : [];
        return choices.filter(choice => choice !== state.current);
    }

    function groupListHeight(group) {
        const count = additionalChoices(group).length;
        return Math.min(count, 10) * choiceRowHeight;
    }

    function groupExpandedHeight(group) {
        const listHeight = groupListHeight(group);
        return expandedGroups[group] === true && listHeight > 0 ? listSeparatorHeight + listHeight : 0;
    }

    function latestDelay(row) {
        if (!row || !row.history || row.history.length === 0)
            return -1;
        return row.history[row.history.length - 1].delay;
    }

    function statFor(name) {
        for (let i = 0; i < stats.length; i++) {
            if (stats[i].name === name)
                return stats[i];
        }
        return {
            name: name,
            displayName: name,
            history: []
        };
    }

    function choiceLabel(name) {
        const stat = statFor(name);
        if (stat.displayName && stat.displayName !== name)
            return UiText.displayName(name) + " (" + UiText.displayName(stat.displayName) + ")";
        return UiText.displayName(name);
    }

    function delayColor(delay) {
        // Match MetaCubeXD's HTTPS latency ladder: <=800 good, <=1500 medium.
        if (delay < 0)
            return Theme.surfaceVariantText;
        if (delay <= 800)
            return "#20c778";
        if (delay <= 1500)
            return "#e5ae32";
        return "#e85c5c";
    }

    function historyColor(delay) {
        // A failed probe is a distinct state, not a slow red connection.
        return delay < 0 ? "#000000" : delayColor(delay);
    }

    Timer {
        interval: 0
        // PluginComponent loads saved settings when the service and ID arrive.
        // Defer until that initialization has completed; never retry on polls
        // or settings changes after the startup decision has been made.
        running: root.pluginService !== null && root.pluginId !== "" && !root.startupHandled
        onTriggered: root.applyStartupPreference()
    }

    Timer {
        id: refreshTimer
        interval: 5000
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    Timer {
        id: selectionRefreshTimer
        interval: 700
        repeat: false
        onTriggered: root.refresh()
    }

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS
            DankIcon {
                name: root.indicatorError ? "error" : (root.active ? "shield" : "shield_off")
                color: root.indicatorError ? Theme.error : (root.active ? Theme.primary : Theme.error)
                size: Theme.iconSize - 6
                anchors.verticalCenter: parent.verticalCenter
            }
            StyledText {
                text: root.label
                color: root.active ? Theme.surfaceText : Theme.error
                font.pixelSize: Theme.fontSizeSmall
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXS
            DankIcon {
                name: root.indicatorError ? "error" : (root.active ? "shield" : "shield_off")
                color: root.indicatorError ? Theme.error : (root.active ? Theme.primary : Theme.error)
                size: Theme.iconSize - 6
                anchors.horizontalCenter: parent.horizontalCenter
            }
            StyledText {
                text: root.active ? "VPN" : "OFF"
                color: root.active ? Theme.surfaceText : Theme.error
                font.pixelSize: Theme.fontSizeSmall
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    popoutContent: Component {
        PopoutComponent {
            id: popup

            headerText: "Mihomo VPN"
            detailsText: ""
            showCloseButton: false

            function commitGeometry() {
                if (!parentPopout || !parentPopout.shouldBeVisible)
                    return;
                Qt.callLater(() => {
                    if (parentPopout && parentPopout.shouldBeVisible)
                        parentPopout.updateSurfacePosition();
                });
            }

            onImplicitHeightChanged: commitGeometry()

            // DMS otherwise interpolates both height and Y position when a
            // group opens, making the entire surface visibly travel.
            onParentPopoutChanged: {
                root.popoutTarget = parentPopout;
                if (parentPopout) {
                    parentPopout.animationDuration = 0;
                    parentPopout.suspendShadowWhileResizing = true;
                }
            }

            headerActions: Component {
                Row {
                    spacing: Theme.spacingXS
                    Rectangle {
                        id: vpnSwitch
                        objectName: "vpnModeSwitch"
                        width: 64
                        height: 32
                        radius: height / 2
                        color: root.active ? Theme.withAlpha(Theme.primary, 0.28) : Theme.surfaceContainerHigh
                        border.width: 1
                        border.color: root.controlError ? Theme.error : (root.active ? Theme.primary : Theme.outlineVariant)
                        opacity: root.toggling ? 0.65 : 1

                        Rectangle {
                            width: 24
                            height: 24
                            radius: width / 2
                            x: root.active ? parent.width - width - 4 : 4
                            anchors.verticalCenter: parent.verticalCenter
                            color: root.active ? Theme.primary : Theme.surfaceVariantText
                            Behavior on x {
                                NumberAnimation {
                                    duration: 140
                                    easing.type: Easing.OutCubic
                                }
                            }
                        }
                        MouseArea {
                            id: vpnSwitchArea
                            objectName: "vpnModeToggle"
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            enabled: !root.toggling
                            onClicked: root.toggleVpn()
                        }
                        ToolTip.visible: vpnSwitchArea.containsMouse
                        ToolTip.text: !root.available ? "Start Mihomo and apply the selected mode" : (root.active ? "Disable VPN and route directly" : "Enable VPN")
                    }
                    Item {
                        width: Theme.spacingS
                        height: 1
                    }
                    Rectangle {
                        objectName: "subscriptionUpdateButton"
                        width: 32
                        height: 32
                        radius: Theme.cornerRadius
                        color: subscriptionArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh
                        DankIcon {
                            anchors.centerIn: parent
                            name: root.subscriptionBusy ? "hourglass_top" : "cloud_download"
                            size: 18
                            color: root.visibleSubscriptionError ? Theme.error : Theme.primary
                        }
                        MouseArea {
                            id: subscriptionArea
                            anchors.fill: parent
                            hoverEnabled: true
                            enabled: !root.subscriptionBusy
                            onClicked: root.updateSubscription()
                        }
                        ToolTip.visible: subscriptionArea.containsMouse
                        ToolTip.text: root.subscriptionTooltip
                    }
                    Rectangle {
                        width: 32
                        height: 32
                        radius: Theme.cornerRadius
                        color: pingArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh
                        DankIcon {
                            id: pingIcon
                            anchors.centerIn: parent
                            name: root.pinging ? "sync" : "speed"
                            size: 18
                            color: Theme.primary
                            smoothTransform: root.pinging
                            RotationAnimator on rotation {
                                from: 0
                                to: 360
                                duration: 1000
                                loops: Animation.Infinite
                                running: root.pinging
                                onRunningChanged: {
                                    if (!running)
                                        pingIcon.rotation = 0;
                                }
                            }
                        }
                        MouseArea {
                            id: pingArea
                            anchors.fill: parent
                            hoverEnabled: true
                            enabled: !root.pinging
                            onClicked: root.pingAll()
                        }
                        ToolTip.visible: pingArea.containsMouse
                        ToolTip.text: root.pinging ? "Checking all nodes…" : "Check all nodes"
                    }
                    Rectangle {
                        width: 32
                        height: 32
                        radius: Theme.cornerRadius
                        color: dashboardArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh
                        DankIcon {
                            anchors.centerIn: parent
                            name: "open_in_new"
                            size: 17
                            color: Theme.surfaceText
                        }
                        MouseArea {
                            id: dashboardArea
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: Qt.openUrlExternally(root.dashboardUrl)
                        }
                        ToolTip.visible: dashboardArea.containsMouse
                        ToolTip.text: "Open MetaCubeXD"
                    }
                }
            }

            // Cap the whole group area to the screen. While it fits, this outer
            // viewport stays inert and wheel/touchpad input goes directly to a
            // bounded DankListView inside each expanded group.
            DankFlickable {
                id: groupsViewport
                width: parent.width
                height: root.groupsViewportHeight
                contentWidth: width
                contentHeight: groupsColumn.implicitHeight
                interactive: contentHeight > height
                clip: true

                function clampContentY() {
                    contentY = Math.max(0, Math.min(contentY, Math.max(0, contentHeight - height)));
                }

                onContentHeightChanged: clampContentY()
                onHeightChanged: clampContentY()

                Column {
                    id: groupsColumn
                    width: groupsViewport.width
                    spacing: Theme.spacingS

                    StyledText {
                        width: parent.width
                        height: visible ? root.emptyStateHeight : 0
                        visible: root.displayedGroups.length === 0
                        text: root.available ? "Choose groups in the widget settings" : "Groups will appear once Mihomo starts"
                        color: Theme.surfaceVariantText
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }

                    Repeater {
                        model: root.displayedGroups

                        delegate: Rectangle {
                            id: groupCard
                            property string groupName: modelData
                            property var state: root.groupState(groupName)
                            property string current: state.current || ""
                            property var additionalChoices: root.additionalChoices(groupName)
                            property bool expanded: root.expandedGroups[groupName] === true
                            property int listHeight: root.groupListHeight(groupName)
                            property bool selectable: state.type === "Selector"

                            width: parent.width
                            height: root.groupBaseHeight + (expanded && listHeight > 0 ? root.listSeparatorHeight + listHeight : 0)
                            radius: Theme.cornerRadius
                            color: Theme.surfaceContainerHigh
                            border.width: 1
                            border.color: Theme.outlineVariant
                            clip: true

                            Rectangle {
                                id: groupHeader
                                width: parent.width
                                height: 38
                                color: groupHeaderArea.containsMouse && groupCard.additionalChoices.length > 0 ? Theme.surfaceContainerHighest : "transparent"

                                DankIcon {
                                    id: groupIcon
                                    name: "route"
                                    size: 18
                                    color: Theme.primary
                                    anchors.left: parent.left
                                    anchors.leftMargin: Theme.spacingM
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                StyledText {
                                    text: UiText.displayName(groupCard.groupName)
                                    color: Theme.surfaceText
                                    anchors.left: groupIcon.right
                                    anchors.leftMargin: Theme.spacingS
                                    anchors.right: groupExpandIcon.left
                                    anchors.rightMargin: Theme.spacingS
                                    anchors.verticalCenter: parent.verticalCenter
                                    elide: Text.ElideRight
                                }
                                DankIcon {
                                    id: groupExpandIcon
                                    name: groupCard.expanded ? "expand_less" : "expand_more"
                                    size: 18
                                    color: Theme.surfaceText
                                    visible: groupCard.additionalChoices.length > 0
                                    anchors.right: parent.right
                                    anchors.rightMargin: Theme.spacingM
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                MouseArea {
                                    id: groupHeaderArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    enabled: groupCard.additionalChoices.length > 0
                                    onClicked: root.toggleGroup(groupCard.groupName)
                                }
                            }

                            Rectangle {
                                y: 38
                                width: parent.width
                                height: 1
                                color: Theme.outlineVariant
                                opacity: 0.55
                            }

                            Rectangle {
                                id: currentRow
                                property var stat: root.statFor(groupCard.current)
                                property int latest: root.latestDelay(stat)
                                y: 39
                                width: parent.width
                                height: 29
                                color: Theme.withAlpha(Theme.primary, 0.08)

                                Row {
                                    id: currentHistory
                                    anchors.right: parent.right
                                    anchors.rightMargin: Theme.spacingM
                                    anchors.verticalCenter: parent.verticalCenter
                                    height: 17
                                    spacing: 2
                                    Repeater {
                                        model: (currentRow.stat.history || []).slice(-8)
                                        delegate: Rectangle {
                                            width: 3
                                            height: Math.max(3, Math.min(14, Math.round((modelData.delay < 0 ? 700 : modelData.delay) / 45)))
                                            anchors.bottom: parent.bottom
                                            radius: 1
                                            color: root.historyColor(modelData.delay)
                                        }
                                    }
                                }
                                StyledText {
                                    id: currentDelay
                                    anchors.right: currentHistory.left
                                    anchors.rightMargin: 5
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: currentRow.latest >= 0 ? currentRow.latest + " ms" : "—"
                                    color: root.delayColor(currentRow.latest)
                                    font.pixelSize: Theme.fontSizeSmall
                                }
                                StyledText {
                                    anchors.left: parent.left
                                    anchors.leftMargin: Theme.spacingM
                                    anchors.right: currentDelay.left
                                    anchors.rightMargin: 7
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: groupCard.current ? root.choiceLabel(groupCard.current) : "—"
                                    color: Theme.primary
                                    elide: Text.ElideRight
                                }
                            }

                            Rectangle {
                                visible: groupCard.expanded && groupCard.listHeight > 0
                                y: root.groupBaseHeight
                                width: parent.width
                                height: root.listSeparatorHeight
                                color: Theme.outlineVariant
                                opacity: 0.55
                            }

                            DankListView {
                                id: choicesList
                                x: 1
                                y: root.groupBaseHeight + root.listSeparatorHeight
                                width: parent.width - 2
                                height: visible ? groupCard.listHeight : 0
                                visible: groupCard.expanded && groupCard.additionalChoices.length > 0
                                model: groupCard.additionalChoices
                                interactive: contentHeight > height
                                clip: true

                                delegate: Rectangle {
                                    id: choiceRow
                                    property string choiceName: modelData || ""
                                    property var stat: root.statFor(choiceName)
                                    property int latest: root.latestDelay(stat)
                                    width: choicesList.width
                                    height: root.choiceRowHeight
                                    color: choiceArea.containsMouse && groupCard.selectable ? Theme.surfaceContainerHighest : "transparent"

                                    StyledText {
                                        anchors.left: parent.left
                                        anchors.leftMargin: Theme.spacingM
                                        anchors.right: choiceDelay.left
                                        anchors.rightMargin: 6
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: root.choiceLabel(choiceRow.choiceName)
                                        color: Theme.surfaceText
                                        elide: Text.ElideRight
                                    }
                                    StyledText {
                                        id: choiceDelay
                                        anchors.right: choiceHistory.left
                                        anchors.rightMargin: 5
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: choiceRow.latest >= 0 ? choiceRow.latest + " ms" : "—"
                                        color: root.delayColor(choiceRow.latest)
                                        font.pixelSize: Theme.fontSizeSmall
                                    }
                                    Row {
                                        id: choiceHistory
                                        anchors.right: parent.right
                                        anchors.rightMargin: Theme.spacingM
                                        anchors.verticalCenter: parent.verticalCenter
                                        height: 18
                                        spacing: 2
                                        Repeater {
                                            model: (choiceRow.stat.history || []).slice(-8)
                                            delegate: Rectangle {
                                                width: 3
                                                height: Math.max(3, Math.min(15, Math.round((modelData.delay < 0 ? 700 : modelData.delay) / 45)))
                                                anchors.bottom: parent.bottom
                                                radius: 1
                                                color: root.historyColor(modelData.delay)
                                            }
                                        }
                                    }
                                    Rectangle {
                                        visible: index < choicesList.count - 1
                                        anchors.bottom: parent.bottom
                                        width: parent.width
                                        height: 1
                                        color: Theme.outlineVariant
                                        opacity: 0.45
                                    }
                                    MouseArea {
                                        id: choiceArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        enabled: groupCard.selectable
                                        onClicked: root.select(groupCard.groupName, choiceRow.choiceName)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    popoutWidth: 400
    popoutHeight: root.popoutHeaderHeight + root.groupsViewportHeight + Theme.spacingS * 2
}
