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
    property bool serviceRunning: false
    property bool tunEnabled: false
    property bool serviceBusy: false
    property bool tunBusy: false
    property bool statusLoaded: false
    property bool startupHandled: false
    property bool pinging: false
    property string serviceError: ""
    readonly property string controlError: serviceError || (!available ? "Mihomo API is unavailable." : "")
    property bool updatingSubscription: false
    property var httpProviders: []
    property var subscriptionFailures: []
    readonly property bool canUpdateSubscriptions: available && httpProviders.length > 0
    readonly property string subscriptionError: subscriptionFailures.map(result => UiText.displayName(result.name) + ": " + result.error).join("\n")
    readonly property bool subscriptionBusy: updatingSubscription
    readonly property string visibleSubscriptionError: canUpdateSubscriptions && !subscriptionBusy ? subscriptionError : ""
    readonly property string indicatorError: visibleSubscriptionError || controlError
    readonly property string subscriptionTooltip: subscriptionError ? "Retry subscription updates" : "Update subscriptions"
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
            return "";
        if (groupStates.length > 0) {
            const first = groupStates[0];
            return UiText.displayName(first.shownCurrent || first.current || first.name || "ON");
        }
        return "ON";
    }
    readonly property string barDisplayMode: {
        const mode = pluginData.barDisplayMode;
        return mode === "emoji" || mode === "icon" ? mode : "full";
    }
    readonly property string barText: {
        if (!active || barDisplayMode === "icon")
            return "";
        if (barDisplayMode === "emoji")
            return UiText.emojiOf(label);
        return label;
    }
    // The vertical bar is narrow: the full mode keeps its short VPN caption.
    readonly property string verticalBarText: {
        if (barDisplayMode === "emoji")
            return barText;
        return barDisplayMode === "full" && active ? "VPN" : "";
    }
    readonly property string iconState: {
        if (!statusLoaded)
            return "default";
        if (!available)
            return "disconnected";
        return active ? "connected" : "direct";
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

    // Shield indicator with the connection state drawn inside it. Material
    // Symbols has no shield-with-cross glyph, so the mark is composited.
    component IndicatorIcon: Item {
        id: indicator

        property string state: "default"
        property real size: 18
        property color color: Theme.surfaceText

        implicitWidth: size
        implicitHeight: size

        readonly property string mark: state === "disconnected" ? "close" : (state === "direct" ? "arrow_upward" : "")

        DankIcon {
            name: indicator.state === "connected" ? "verified_user" : "shield"
            size: indicator.size
            color: indicator.color
            anchors.centerIn: parent
        }

        DankIcon {
            visible: indicator.mark !== ""
            name: indicator.mark
            size: Math.max(6, Math.round(indicator.size * 0.44))
            color: indicator.color
            anchors.centerIn: parent
        }
    }

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
        if (toggling)
            return;
        const requestedGroups = configuredGroups.slice();
        const requestKey = JSON.stringify(requestedGroups);
        const generation = ++refreshGeneration;
        Proc.runCommand("mihomoVpn.status", [helper, "status"].concat(requestedGroups), (output, exitCode) => {
            if (generation !== refreshGeneration || requestKey !== JSON.stringify(configuredGroups))
                return;
            let data = null;
            try {
                data = JSON.parse(output);
            } catch (error) {
                markControllerUnavailable();
                return;
            }
            if (!data || typeof data.available !== "boolean") {
                markControllerUnavailable();
                return;
            }
            statusLoaded = true;
            if (typeof data.serviceRunning === "boolean")
                serviceRunning = data.serviceRunning;
            if (typeof data.tunEnabled === "boolean")
                tunEnabled = data.tunEnabled;
            if (data.available !== true) {
                markControllerUnavailable();
                return;
            }
            available = true;
            active = data.active === true;
            applyHttpProviders(data.httpProviders);
            applyGroupStates(data.groups);
            applyStats(data.stats);
            if (pluginService !== null && pluginId !== "")
                applyStartupPreference();
        }, 0, 11000);
    }

    function markControllerUnavailable() {
        available = false;
        statusLoaded = true;
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
            if ("active" in result)
                active = result.active === true;
            if ("available" in result)
                available = result.available === true;
            if ("serviceRunning" in result)
                serviceRunning = result.serviceRunning === true;
            if ("tunEnabled" in result)
                tunEnabled = result.tunEnabled === true;
            showInfo("Mihomo VPN", successMessage);
        } else {
            if (result && result.available === false)
                markControllerUnavailable();
            serviceError = UiText.englishError(result && result.error, "Could not control Mihomo. Check the local controller.");
            if (typeof ToastService !== "undefined")
                ToastService.showError("Mihomo VPN", serviceError);
        }
    }

    function startService() {
        if (serviceBusy)
            return;
        serviceBusy = true;
        Proc.runCommand("mihomoVpn.startService", [helper, "service-start"], (output, exitCode) => {
            serviceBusy = false;
            applyControlResult(output, exitCode, "Mihomo service started");
            refresh();
        }, 0, 20000);
    }

    function stopService() {
        if (serviceBusy)
            return;
        serviceBusy = true;
        Proc.runCommand("mihomoVpn.stopService", [helper, "service-stop"], (output, exitCode) => {
            serviceBusy = false;
            applyControlResult(output, exitCode, "Mihomo service stopped");
            refresh();
        }, 0, 60000);
    }

    function setTunEnabled(enabled) {
        if (tunBusy)
            return;
        tunBusy = true;
        Proc.runCommand("mihomoVpn.tun", [helper, enabled ? "tun-on" : "tun-off"], (output, exitCode) => {
            tunBusy = false;
            applyControlResult(output, exitCode, enabled ? "TUN mode enabled" : "TUN mode disabled");
            refresh();
        }, 0, 120000);
    }

    function applyHttpProviders(names) {
        const normalized = Array.isArray(names)
            ? names.filter((name, index) => typeof name === "string" && name.length > 0 && names.indexOf(name) === index)
            : [];
        if (!sameStringArray(httpProviders, normalized))
            httpProviders = normalized;
        subscriptionFailures = subscriptionFailures.filter(result => normalized.indexOf(result.name) >= 0);
    }

    function applySubscriptionResults(results) {
        subscriptionFailures = results.filter(result => result.ok !== true && httpProviders.indexOf(result.name) >= 0);
    }

    function updateSubscription() {
        if (subscriptionBusy || !canUpdateSubscriptions)
            return;
        updatingSubscription = true;
        const providers = httpProviders.slice();
        const results = [];
        let next = 0;
        function updateNext() {
            if (next === providers.length) {
                root.applySubscriptionResults(results);
                root.updatingSubscription = false;
                const failures = results.filter(result => !result.ok);
                if (failures.length > 0 && typeof ToastService !== "undefined") {
                    ToastService.showError("Subscription update failed",
                        failures.map(result => UiText.displayName(result.name) + ": " + result.error).join("\n"));
                } else if (failures.length === 0) {
                    root.showInfo("Mihomo VPN", "Updated subscriptions: " + results.length);
                }
                root.refresh();
                return;
            }
            const name = providers[next++];
            Proc.runCommand("mihomoVpn.updateProvider." + encodeURIComponent(name), [root.helper, "update-provider", name], (output, exitCode) => {
                let result = null;
                try {
                    result = JSON.parse(output);
                } catch (error) {}
                results.push({name: name, ok: exitCode === 0 && result !== null && result.ok === true,
                    error: UiText.englishError(result && result.error, "Could not update this provider through Mihomo.")});
                updateNext();
            }, 0, 70000);
        }
        updateNext();
    }

    function toggleVpn() {
        if (!available || toggling)
            return;
        startupHandled = true;
        setVpnEnabled(!active);
    }

    function applyStartupPreference() {
        if (startupHandled)
            return;
        if (pluginData.enableVpnOnStartup === true && !available)
            return;
        startupHandled = true;
        if (pluginData.enableVpnOnStartup === true)
            setVpnEnabled(true);
    }

    function setVpnEnabled(enabled) {
        if (toggling || !available)
            return;
        const requestedState = enabled ? "on" : "off";
        ++refreshGeneration;
        toggling = true;
        Proc.runCommand("mihomoVpn.setVpn", [helper, "set-vpn", requestedState], (output, exitCode) => {
            toggling = false;
            applyControlResult(output, exitCode, requestedState === "on" ? "VPN enabled" : "VPN disabled: direct connection");
            refresh();
        }, 0, 15000);
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

    function groupChoices(group) {
        const state = groupState(group);
        return Array.isArray(state.choices) ? state.choices : [];
    }

    function groupListHeight(group) {
        const count = groupChoices(group).length;
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
            return Theme.success;
        if (delay <= 1500)
            return Theme.warning;
        return Theme.error;
    }

    function historyColor(delay) {
        // A failed probe is a distinct state, not a slow red connection.
        return delay < 0 ? Theme.surfaceVariantText : delayColor(delay);
    }

    function visibleHistory(stat) {
        return (stat.history || []).slice(-4);
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
            IndicatorIcon {
                state: root.iconState
                size: Theme.iconSize - 6
                color: root.indicatorError ? Theme.error : (root.active ? Theme.primary : Theme.surfaceVariantText)
                anchors.verticalCenter: parent.verticalCenter
            }
            StyledText {
                text: root.barText
                visible: text !== ""
                color: root.active ? Theme.surfaceText : Theme.surfaceVariantText
                font.pixelSize: Theme.fontSizeSmall
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXS
            IndicatorIcon {
                state: root.iconState
                size: Theme.iconSize - 6
                color: root.indicatorError ? Theme.error : (root.active ? Theme.primary : Theme.surfaceVariantText)
                anchors.horizontalCenter: parent.horizontalCenter
            }
            StyledText {
                text: root.verticalBarText
                visible: text !== ""
                color: root.active ? Theme.surfaceText : Theme.surfaceVariantText
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
                    DankActionButton {
                        objectName: "serviceControlButton"
                        buttonSize: 32
                        iconSize: 18
                        iconName: root.serviceBusy ? "hourglass_top" : (root.serviceRunning ? "stop_circle" : "play_arrow")
                        iconColor: root.serviceBusy ? Theme.onSecondaryContainer : (root.serviceRunning ? Theme.error : Theme.primary)
                        backgroundColor: root.serviceBusy ? Theme.secondaryContainer : Theme.ccPillInactiveBg
                        enabled: !root.serviceBusy
                        tooltipText: root.serviceRunning ? "Stop Mihomo service" : "Start Mihomo service"
                        onClicked: root.serviceRunning ? root.stopService() : root.startService()
                    }
                    DankActionButton {
                        objectName: "tunControlButton"
                        buttonSize: 32
                        iconSize: 18
                        iconName: root.tunBusy ? "hourglass_top" : "route"
                        iconColor: root.tunBusy ? Theme.onSecondaryContainer : (root.tunEnabled ? Theme.onPrimary : Theme.primary)
                        backgroundColor: root.tunBusy ? Theme.secondaryContainer : (root.tunEnabled ? Theme.primary : Theme.ccPillInactiveBg)
                        enabled: root.available && !root.tunBusy
                        tooltipText: root.tunEnabled ? "Disable TUN mode" : "Enable TUN mode"
                        onClicked: root.setTunEnabled(!root.tunEnabled)
                    }
                    DankToggle {
                        id: vpnSwitch
                        objectName: "vpnModeSwitch"
                        anchors.verticalCenter: parent.verticalCenter
                        checked: root.active
                        toggling: root.toggling
                        enabled: root.available && !root.toggling
                        Accessible.name: root.active ? "Disable VPN" : "Enable VPN"
                        onToggled: root.toggleVpn()

                        HoverHandler { id: vpnSwitchHover }
                        ToolTip.visible: vpnSwitchHover.hovered
                        ToolTip.text: root.active ? "Disable VPN" : "Enable VPN"
                    }
                    Item {
                        width: Theme.spacingXS
                        height: 1
                    }
                    DankActionButton {
                        objectName: "subscriptionUpdateButton"
                        visible: root.canUpdateSubscriptions
                        buttonSize: 32
                        iconSize: 18
                        iconName: root.subscriptionBusy ? "hourglass_top" : "cloud_download"
                        iconColor: root.subscriptionBusy ? Theme.onSecondaryContainer : root.visibleSubscriptionError ? Theme.error : Theme.primary
                        backgroundColor: root.subscriptionBusy ? Theme.secondaryContainer : Theme.ccPillInactiveBg
                        enabled: root.canUpdateSubscriptions
                        tooltipText: root.subscriptionTooltip
                        onClicked: root.updateSubscription()
                    }
                    DankActionButton {
                        objectName: "latencyCheckButton"
                        buttonSize: 32
                        iconSize: 18
                        iconName: root.pinging ? "hourglass_top" : "speed"
                        iconColor: root.pinging ? Theme.onSecondaryContainer : Theme.primary
                        backgroundColor: root.pinging ? Theme.secondaryContainer : Theme.ccPillInactiveBg
                        tooltipText: "Check all nodes"
                        onClicked: root.pingAll()
                    }
                    DankActionButton {
                        buttonSize: 32
                        iconSize: 18
                        iconName: "open_in_new"
                        iconColor: Theme.primary
                        backgroundColor: Theme.ccPillInactiveBg
                        tooltipText: "Open MetaCubeXD"
                        onClicked: Qt.openUrlExternally(root.dashboardUrl)
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
                            property var groupChoices: root.groupChoices(groupName)
                            property bool expanded: root.expandedGroups[groupName] === true
                            property int listHeight: root.groupListHeight(groupName)
                            property bool selectable: state.type === "Selector"

                            width: parent.width
                            height: root.groupBaseHeight + (expanded && listHeight > 0 ? root.listSeparatorHeight + listHeight : 0)
                            radius: Theme.cornerRadiusL
                            color: Theme.ccPillInactiveBg
                            clip: true

                            StyledButton {
                                id: groupHeader
                                objectName: "groupHeader:" + groupCard.groupName
                                width: parent.width
                                height: root.groupBaseHeight
                                radius: Theme.cornerRadiusL
                                enabled: groupCard.groupChoices.length > 0
                                Accessible.name: UiText.displayName(groupCard.groupName)
                                Accessible.description: groupCard.expanded ? "Collapse group" : "Expand group"
                                onClicked: root.toggleGroup(groupCard.groupName)

                                Rectangle {
                                    id: groupIconBox
                                    width: 40
                                    height: 40
                                    radius: Theme.cornerRadiusM
                                    color: root.active ? Theme.primary : Theme.ccIconBoxInactiveBg
                                    anchors.left: parent.left
                                    anchors.leftMargin: Theme.spacingM
                                    anchors.verticalCenter: parent.verticalCenter

                                    DankIcon {
                                        anchors.centerIn: parent
                                        name: "route"
                                        size: Theme.iconSize
                                        color: root.active ? Theme.onPrimary : Theme.primary
                                    }
                                }
                                StyledText {
                                    text: UiText.displayName(groupCard.groupName)
                                    color: Theme.surfaceText
                                    font.weight: Font.Medium
                                    anchors.left: groupIconBox.right
                                    anchors.leftMargin: Theme.spacingM
                                    anchors.right: groupExpandIcon.left
                                    anchors.rightMargin: Theme.spacingS
                                    y: Theme.spacingM
                                    elide: Text.ElideRight
                                }
                                DankIcon {
                                    id: groupExpandIcon
                                    name: groupCard.expanded ? "expand_less" : "expand_more"
                                    size: 18
                                    color: Theme.surfaceVariantText
                                    visible: groupCard.groupChoices.length > 0
                                    anchors.right: parent.right
                                    anchors.rightMargin: Theme.spacingM
                                    y: Theme.spacingM
                                }
                                StateLayer {
                                    control: groupHeader
                                    disabled: !groupHeader.enabled
                                    stateColor: Theme.primary
                                }
                                FocusRing { visible: groupHeader.visualFocus }
                            }

                            Rectangle {
                                id: currentRow
                                property var stat: root.statFor(groupCard.current)
                                property int latest: root.latestDelay(stat)
                                x: Theme.spacingM + 40 + Theme.spacingM
                                y: 34
                                width: parent.width - x
                                height: 24
                                color: "transparent"

                                Row {
                                    id: currentHistory
                                    objectName: "currentHistory"
                                    anchors.right: parent.right
                                    anchors.rightMargin: Theme.spacingM
                                    anchors.verticalCenter: parent.verticalCenter
                                    height: 17
                                    spacing: 2
                                    Repeater {
                                        model: root.visibleHistory(currentRow.stat)
                                        delegate: Rectangle {
                                            objectName: "latencyHistoryBar"
                                            width: 6
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
                                    anchors.leftMargin: 0
                                    anchors.right: currentDelay.left
                                    anchors.rightMargin: 7
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: groupCard.current ? root.choiceLabel(groupCard.current) : "—"
                                    color: Theme.surfaceVariantText
                                    font.pixelSize: Theme.fontSizeSmall
                                    elide: Text.ElideRight
                                }
                            }

                            Rectangle {
                                visible: groupCard.expanded && groupCard.listHeight > 0
                                y: root.groupBaseHeight
                                x: Theme.spacingM
                                width: parent.width - Theme.spacingM * 2
                                height: root.listSeparatorHeight
                                color: Theme.outlineVariant
                                opacity: 0.35
                            }

                            DankListView {
                                id: choicesList
                                x: Theme.spacingS
                                y: root.groupBaseHeight + root.listSeparatorHeight
                                width: parent.width - Theme.spacingS * 2
                                height: visible ? groupCard.listHeight : 0
                                visible: groupCard.expanded && groupCard.groupChoices.length > 0
                                model: groupCard.groupChoices
                                interactive: contentHeight > height
                                clip: true

                                delegate: StyledButton {
                                    id: choiceRow
                                    objectName: "choice:" + groupCard.groupName + ":" + choiceName
                                    property string choiceName: modelData || ""
                                    readonly property bool selected: choiceName === groupCard.current
                                    property var stat: root.statFor(choiceName)
                                    property int latest: root.latestDelay(stat)
                                    width: choicesList.width
                                    height: root.choiceRowHeight
                                    radius: Theme.cornerRadiusS
                                    color: selected ? Theme.secondaryContainer : "transparent"
                                    enabled: groupCard.selectable
                                    Accessible.selected: selected
                                    Accessible.name: root.choiceLabel(choiceName)
                                    onClicked: root.select(groupCard.groupName, choiceName)

                                    StyledText {
                                        anchors.left: parent.left
                                        anchors.leftMargin: Theme.spacingM
                                        anchors.right: choiceDelay.left
                                        anchors.rightMargin: 6
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: root.choiceLabel(choiceRow.choiceName)
                                        color: choiceRow.selected ? Theme.onSecondaryContainer : Theme.surfaceText
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
                                        objectName: "choiceHistory"
                                        anchors.right: parent.right
                                        anchors.rightMargin: Theme.spacingM
                                        anchors.verticalCenter: parent.verticalCenter
                                        height: 18
                                        spacing: 2
                                        Repeater {
                                            model: root.visibleHistory(choiceRow.stat)
                                            delegate: Rectangle {
                                                objectName: "latencyHistoryBar"
                                                width: 6
                                                height: Math.max(3, Math.min(15, Math.round((modelData.delay < 0 ? 700 : modelData.delay) / 45)))
                                                anchors.bottom: parent.bottom
                                                radius: 1
                                                color: root.historyColor(modelData.delay)
                                            }
                                        }
                                    }
                                    StateLayer {
                                        control: choiceRow
                                        disabled: !choiceRow.enabled
                                        stateColor: Theme.secondary
                                    }
                                    FocusRing { visible: choiceRow.visualFocus }
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
