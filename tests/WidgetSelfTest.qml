import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import "plugin" as Mihomo
import "plugin/UiText.js" as UiText

ShellRoot {
    id: shell

    property var widget: null
    property var popup: null
    property var longList: null

    Component {
        id: widgetComponent
        Mihomo.MihomoVpnWidget {}
    }

    Component {
        id: startupWidgetComponent
        Mihomo.MihomoVpnWidget {
            property var enableRequests: []
            function setVpnEnabled(enabled) {
                enableRequests = enableRequests.concat([enabled]);
            }
        }
    }

    FileView {
        id: pluginManifest
        path: Qt.resolvedUrl("plugin/plugin.json")
        blockLoading: true
    }

    QtObject {
        id: settingsService
        property var savedGroups: ["Russia", "Foreign"]
        signal pluginDataChanged(string pluginId)
        function getPluginVariants(pluginId) { return []; }
        function loadPluginData(pluginId, key, fallback) {
            return key === "visibleGroups" ? savedGroups : fallback;
        }
        function savePluginData(pluginId, key, value) {
            if (key === "visibleGroups")
                savedGroups = value.slice();
        }
    }

    function testSettingsAndStartup() {
        const manifest = JSON.parse(pluginManifest.text());
        assertTrue(manifest.settings.endsWith("?v=" + manifest.version),
            "settings URL is not versioned; DMS can reuse stale settings after an update");
        const settingsComponent = Qt.createComponent(Qt.resolvedUrl("plugin/" + manifest.settings));
        assertTrue(settingsComponent.status === Component.Ready, settingsComponent.errorString());
        const settings = settingsComponent.createObject(null, {width: 500, pluginService: settingsService});
        settings.availableGroups = ["GLOBAL", "Foreign", "Russia"].map(name => ({name: name, type: "Selector"}));
        settings.loadSavedGroups();
        assertTrue(JSON.stringify(settings.orderedGroupNames) === '["Russia","Foreign","GLOBAL"]',
            "settings did not place selected groups first in their saved order");
        settings.moveTo("Foreign", 0);
        assertTrue(JSON.stringify(settingsService.savedGroups) === '["Foreign","Russia"]',
            "drag reorder did not save the new widget order");
        settings.toggleGroup("Foreign");
        assertTrue(JSON.stringify(settings.orderedGroupNames) === '["Russia","GLOBAL","Foreign"]',
            "disabled group did not move below all enabled groups");
        settings.moveTo("Foreign", 0);
        assertTrue(JSON.stringify(settingsService.savedGroups) === '["Russia"]',
            "dragging a disabled group changed the widget selection");
        settings.toggleGroup("GLOBAL");
        assertTrue(JSON.stringify(settingsService.savedGroups) === '["Russia","GLOBAL"]',
            "enabling a group did not append it to the enabled order");
        settings.destroy();

        const startupWidget = startupWidgetComponent.createObject(null);
        startupWidget.applyStartupPreference();
        assertTrue(startupWidget.enableRequests.length === 0, "startup default enabled VPN");
        startupWidget.pluginData = {enableVpnOnStartup: true};
        startupWidget.applyStartupPreference();
        assertTrue(startupWidget.enableRequests.length === 0, "changing settings triggered startup again");
        startupWidget.startupHandled = false;
        startupWidget.applyStartupPreference();
        assertTrue(!startupWidget.startupHandled && startupWidget.enableRequests.length === 0,
            "startup did not wait for the Mihomo API");
        startupWidget.available = true;
        startupWidget.active = true;
        startupWidget.applyStartupPreference();
        assertTrue(JSON.stringify(startupWidget.enableRequests) === '[true]',
            "startup did not explicitly enable VPN (or toggled an active VPN off)");
        startupWidget.active = false;
        startupWidget.applyStartupPreference();
        assertTrue(startupWidget.enableRequests.length === 1, "startup undid a later manual OFF");
        startupWidget.startupHandled = false;
        startupWidget.toggleVpn();
        startupWidget.applyStartupPreference();
        assertTrue(startupWidget.startupHandled && startupWidget.enableRequests.length === 2,
            "manual toggle did not consume the pending startup preference");
        startupWidget.destroy();
    }

    function assertTrue(condition, message) {
        if (!condition)
            throw new Error(message);
    }

    function choices(prefix, count) {
        const result = [];
        for (let i = 0; i < count; i++)
            result.push(prefix + i);
        return result;
    }

    function findLongList(item) {
        if (!item)
            return null;
        try {
            if (typeof item.contentY === "number" && typeof item.count === "number" && item.count >= 20)
                return item;
        } catch (error) {
        }
        const itemChildren = item.children || [];
        for (let i = 0; i < itemChildren.length; i++) {
            const match = findLongList(itemChildren[i]);
            if (match)
                return match;
        }
        return null;
    }

    function findObject(item, name) {
        if (!item)
            return null;
        if (item.objectName === name)
            return item;
        const itemChildren = item.children || [];
        for (let i = 0; i < itemChildren.length; i++) {
            const match = findObject(itemChildren[i], name);
            if (match)
                return match;
        }
        return null;
    }

    function cleanUp() {
        if (popup)
            popup.destroy();
        if (widget)
            widget.destroy();
        Qt.quit();
    }

    function finishScrollTest() {
        try {
            // The invisible harness has no render frame to polish Column layout.
            popup.forceLayout();
            assertTrue(Math.abs(longList.contentY - 120) < 1,
                "long-list scroll position was reset by an identical refresh");
            assertTrue(popup.implicitHeight === widget.popoutHeaderHeight + widget.groupsViewportHeight,
                "content implicitHeight " + popup.implicitHeight + " does not match calculated viewport height "
                    + (widget.popoutHeaderHeight + widget.groupsViewportHeight));
            assertTrue(widget.popoutHeight === popup.implicitHeight + Theme.spacingS * 2,
                "PluginPopout host height does not match content height");
            widget.available = true;
            widget.applyHttpProviders(["Alpha", "Россия / beta?"]);
            widget.updateSubscription();
            assertTrue(widget.updatingSubscription, "HTTP provider update did not start");
            // A second click while busy must not create a second batch.
            widget.updateSubscription();
            providerUpdateTestTimer.start();
        } catch (error) {
            console.error("MIHOMO_SELFTEST_FAIL", error.message);
            cleanUp();
        }
    }

    Timer {
        id: providerUpdateTestTimer
        property bool retrying: false
        interval: 30
        repeat: true
        onTriggered: {
            if (shell.widget.updatingSubscription)
                return;
            try {
                if (!retrying) {
                    shell.assertTrue(shell.widget.subscriptionFailures.length === 1
                        && shell.widget.subscriptionFailures[0].name === "Alpha",
                        "partial HTTP failure was lost or the next provider failed unexpectedly");
                    retrying = true;
                    shell.widget.available = true;
                    shell.widget.applyHttpProviders(["Alpha", "Россия / beta?"]);
                    shell.widget.updateSubscription();
                    return;
                }
                shell.assertTrue(shell.widget.subscriptionError === "", "successful HTTP retry left a stale error");
                stop();
                shell.widget.setVpnEnabled(false);
                shell.assertTrue(shell.widget.toggling, "API OFF did not start");
                // Busy control must reject a second click.
                shell.widget.setVpnEnabled(true);
                vpnControlTestTimer.start();
                return;
            } catch (error) {
                console.error("MIHOMO_SELFTEST_FAIL", error.message);
            }
            stop();
            shell.cleanUp();
        }
    }

    Timer {
        id: vpnControlTestTimer
        property bool enabling: false
        interval: 30
        repeat: true
        onTriggered: {
            if (shell.widget.toggling)
                return;
            try {
                shell.assertTrue(shell.widget.available && shell.widget.serviceError === "",
                    "API mode control failed");
                shell.assertTrue(shell.widget.active === enabling, "API mode result was not applied");
                if (!enabling) {
                    enabling = true;
                    shell.widget.setVpnEnabled(true);
                    return;
                }
                console.warn("MIHOMO_SELFTEST_PASS bundled-bridge independent-expansion bounded-heights interactive-scroll stable-scroll exact-host-height http-provider-batch partial-failure retry api-vpn-off-on");
            } catch (error) {
                console.error("MIHOMO_SELFTEST_FAIL", error.message);
            }
            stop();
            shell.cleanUp();
        }
    }

    function finishGeometryTest() {
        try {
            for (const name of ["currentHistory", "choiceHistory"]) {
                const row = findObject(popup, name);
                assertTrue(row !== null, name + " was not instantiated");
                const bars = Array.from(row.children).filter(child => child.objectName === "latencyHistoryBar");
                assertTrue(bars.length === 4, name + " must show exactly four recent samples");
                assertTrue(bars.every(bar => bar.width === 6), name + " bars must be 6 px wide");
                assertTrue(Qt.colorEqual(bars[3].color, Theme.surfaceVariantText),
                    name + " failed sample does not use the visible theme color");
            }
            const selected = findObject(popup, "choice:Foreign:f1");
            const other = findObject(popup, "choice:Foreign:f2");
            assertTrue(selected !== null && other !== null, "current server is missing from the choices");
            assertTrue(Qt.colorEqual(selected.color, Theme.secondaryContainer),
                "current server does not use the secondary accent container");
            assertTrue(other.color.a === 0, "inactive server has a persistent highlight");
            longList = findLongList(popup);
            assertTrue(longList !== null, "long DankListView was not instantiated");
            assertTrue(longList.interactive === true, "long DankListView is not interactive");
            assertTrue(longList.contentHeight > longList.height, "long DankListView has no scroll range");
            longList.contentY = 120;
            widget.applyGroupStates(JSON.parse(JSON.stringify(widget.groupStates)));
            Qt.callLater(finishScrollTest);
        } catch (error) {
            console.error("MIHOMO_SELFTEST_FAIL", error.message);
            cleanUp();
        }
    }

    function runTests() {
        try {
            testSettingsAndStartup();
            widget = widgetComponent.createObject(null);
            assertTrue(widget !== null, "widget could not be created");
            assertTrue(widget.helper.endsWith("/plugin/mihomo-dms"),
                "widget helper does not resolve inside the plugin directory");
            assertTrue(typeof widget.restartMihomo === "undefined", "restart UI action was not removed");
            assertTrue(UiText.displayName("Зарубежный VPN") === "International VPN", "group label is not English");
            assertTrue(widget.choiceLabel("🇩🇪 Германия") === "🇩🇪 Germany", "server label is not English");
            assertTrue(UiText.englishError("Ошибка", "fallback") === "fallback", "non-English error is not replaced");
            assertTrue(Qt.colorEqual(widget.delayColor(800), Theme.success), "fast latency ignores success theme color");
            assertTrue(Qt.colorEqual(widget.delayColor(801), Theme.warning), "medium latency ignores warning theme color");
            assertTrue(Qt.colorEqual(widget.delayColor(1500), Theme.warning), "medium latency threshold changed");
            assertTrue(Qt.colorEqual(widget.delayColor(1501), Theme.error), "slow latency ignores error theme color");
            assertTrue(Qt.colorEqual(widget.historyColor(-1), Theme.surfaceVariantText), "failed history is not theme-aware");
            const history = [10, 20, 100, 900, 1600, -1].map(delay => ({delay: delay}));
            assertTrue(JSON.stringify(widget.visibleHistory({history: history})) === JSON.stringify(history.slice(-4)),
                "history does not preserve the latest four samples in chronological order");
            assertTrue(widget.visibleHistory({}).length === 0, "missing history produced samples");
            assertTrue(widget.visibleHistory({history: history.slice(0, 2)}).length === 2, "short history was padded");
            widget.groupStates = [
                {name: "Foreign", type: "Selector", current: "f0", shownCurrent: "f0", choices: choices("f", 30)},
                {name: "Russia", type: "Selector", current: "r0", shownCurrent: "r0", choices: choices("r", 3)}
            ];
            widget.displayedGroups = ["Foreign", "Russia"];
            widget.stats = choices("f", 30).concat(choices("r", 3)).map(name => ({name: name, history: history}));
            widget.expandedGroups = ({});

            widget.toggleGroup("Foreign");
            widget.toggleGroup("Russia");
            assertTrue(widget.expandedGroups.Foreign === true, "opening Russia closed Foreign");
            assertTrue(widget.expandedGroups.Russia === true, "Russia did not open");
            widget.toggleGroup("Foreign");
            assertTrue(widget.expandedGroups.Foreign !== true, "Foreign did not close independently");
            assertTrue(widget.expandedGroups.Russia === true, "closing Foreign also closed Russia");

            assertTrue(widget.groupListHeight("Foreign") === 10 * widget.choiceRowHeight,
                "30-choice group was not capped at ten visible rows");
            assertTrue(widget.groupListHeight("Russia") === 3 * widget.choiceRowHeight,
                "small group height is incorrect");
            widget.expandedGroups = ({Foreign: true, Russia: true});
            const expectedHeight = widget.collapsedGroupsHeight
                + widget.listSeparatorHeight * 2
                + 13 * widget.choiceRowHeight;
            assertTrue(widget.groupsContentHeight === expectedHeight,
                "expanded content height is off by a divider or row");
            assertTrue(widget.groupsViewportHeight <= widget.maximumGroupsViewportHeight,
                "viewport can grow beyond the screen-safe limit");

            widget.parentScreen = ({height: 320});
            assertTrue(widget.groupsViewportHeight < widget.groupsContentHeight,
                "small screen did not activate the bounded outer viewport");
            assertTrue(widget.groupsViewportHeight <= widget.maximumGroupsViewportHeight,
                "small-screen viewport exceeds its calculated limit");
            widget.parentScreen = null;

            const names = widget.displayedGroups;
            const states = widget.groupStates;
            widget.applyGroupStates(JSON.parse(JSON.stringify(states)));
            assertTrue(widget.displayedGroups === names, "identical refresh recreated the outer model");
            assertTrue(widget.groupStates === states, "identical refresh recreated group state");
            const changed = JSON.parse(JSON.stringify(states));
            changed[0].current = "f1";
            widget.applyGroupStates(changed);
            assertTrue(widget.displayedGroups === names, "current-node refresh recreated group delegates");
            assertTrue(widget.groupStates !== states, "changed current node was not applied");

            widget.active = true;
            widget.markControllerUnavailable();
            assertTrue(widget.active === false, "controller outage left a stale enabled switch position");
            widget.applyControlResult('{"ok":false,"error":"Test failure"}', 1, "unused");
            assertTrue(widget.active === false && widget.serviceError === "Test failure",
                "failed control action hid its reason or changed the switch");
            widget.applyControlResult('{"ok":true,"active":false,"available":true}', 0, "test");
            assertTrue(widget.active === false && widget.available === true && widget.serviceError === "",
                "confirmed control result was not applied");
            popup = widget.popoutContent.createObject(null, {width: 400});
            assertTrue(popup !== null, "popout content could not be created");
            const notice = findObject(popup, "subscriptionStatusCard");
            assertTrue(notice === null, "subscription error added an unwanted inline card");
            const subscriptionButton = findObject(popup, "subscriptionUpdateButton");
            assertTrue(subscriptionButton !== null, "subscription update button missing");
            widget.available = true;
            widget.applyHttpProviders([]);
            assertTrue(!subscriptionButton.visible && widget.indicatorError === "",
                "stock install without HTTP providers shows a subscription button or false error");
            widget.updateSubscription();
            assertTrue(!widget.updatingSubscription, "empty provider list started an update");
            widget.applyHttpProviders(["Alpha", "Россия", "Alpha"]);
            assertTrue(subscriptionButton.visible && widget.httpProviders.length === 2,
                "HTTP providers did not enable the button or were not deduplicated");
            widget.applySubscriptionResults([
                {name: "Alpha", ok: true},
                {name: "Россия", ok: false, error: "Mihomo could not update this provider (HTTP 502)."}
            ]);
            assertTrue(widget.subscriptionError.indexOf("Russia:") === 0 && widget.subscriptionError.indexOf("HTTP 502") >= 0,
                "partial failure lost its provider name, HTTP status or display translation");
            assertTrue(widget.subscriptionTooltip === "Retry subscription updates" && widget.indicatorError.length > 0,
                "failed update lost the compact indicator or short action tooltip");
            widget.active = false;
            widget.applyHttpProviders(["Alpha", "Россия"]);
            assertTrue(widget.visibleSubscriptionError.length > 0, "DIRECT mode or polling cleared an actual update failure");
            widget.updatingSubscription = true;
            assertTrue(widget.visibleSubscriptionError === "" && widget.indicatorError === "",
                "previous subscription failure leaked into the current update indicator");
            assertTrue(widget.subscriptionError.length > 0, "retry destroyed the stored previous error");
            assertTrue(widget.groupsContentHeight === expectedHeight, "update progress expanded the widget");
            widget.applySubscriptionResults([{name: "Alpha", ok: true}, {name: "Россия", ok: true}]);
            widget.updatingSubscription = false;
            assertTrue(widget.subscriptionError === "", "successful retry did not clear the error");
            widget.applyHttpProviders([]);
            widget.applySubscriptionResults([{name: "Россия", ok: false, error: "Late failed request"}]);
            assertTrue(widget.subscriptionError === "" && !subscriptionButton.visible,
                "late callback resurrected an error for a removed provider");
            widget.applyHttpProviders(["Alpha"]);
            widget.markControllerUnavailable();
            assertTrue(!subscriptionButton.visible, "offline controller left provider update available");
            assertTrue(widget.groupsContentHeight === expectedHeight, "idle status changed widget height");
            const vpnSwitch = findObject(popup, "vpnModeSwitch");
            assertTrue(vpnSwitch !== null, "VPN mode switch was not instantiated");
            assertTrue(vpnSwitch.width > vpnSwitch.height && vpnSwitch.checked === widget.active,
                "VPN mode switch does not reflect the controller state");
            assertTrue(!vpnSwitch.enabled && !vpnSwitch.focusTarget.enabled,
                "unavailable controller left the API-only VPN switch enabled");
            assertTrue(findObject(popup, "mihomoServiceStatusCard") === null,
                "controller outage added an unwanted inline card");
            assertTrue(widget.controlError.indexOf("unavailable") >= 0 && widget.indicatorError.length > 0,
                "controller outage lost its compact error indication");
            Qt.callLater(finishGeometryTest);
        } catch (error) {
            console.error("MIHOMO_SELFTEST_FAIL", error.message);
            cleanUp();
        }
    }

    Component.onCompleted: Qt.callLater(runTests)

    Timer {
        interval: 10000
        running: true
        onTriggered: {
            console.error("MIHOMO_SELFTEST_FAIL timeout");
            cleanUp();
        }
    }
}
