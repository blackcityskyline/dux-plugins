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
        startupWidget.active = true;
        startupWidget.applyStartupPreference();
        assertTrue(JSON.stringify(startupWidget.enableRequests) === '[true]',
            "startup did not explicitly enable VPN (or toggled an active VPN off)");
        startupWidget.active = false;
        startupWidget.applyStartupPreference();
        assertTrue(startupWidget.enableRequests.length === 1, "startup undid a later manual OFF");
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
            console.warn("MIHOMO_SELFTEST_PASS bundled-helper independent-expansion bounded-heights interactive-scroll stable-scroll exact-host-height");
        } catch (error) {
            console.error("MIHOMO_SELFTEST_FAIL", error.message);
        }
        cleanUp();
    }

    function finishGeometryTest() {
        try {
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
            assertTrue(UiText.englishError("Не удалось запустить Mihomo. Проверьте журнал mihomo.service.", "fallback")
                === "Could not start Mihomo. Check the mihomo.service journal.", "legacy helper error is not translated");
            assertTrue(UiText.subscriptionError({code: "http_error", error: "Сервер подписки вернул HTTP 502."})
                === "The subscription server returned HTTP 502. Please try again later.", "HTTP error lost its status or language");
            widget.groupStates = [
                {name: "Foreign", type: "Selector", current: "f0", shownCurrent: "f0", choices: choices("f", 30)},
                {name: "Russia", type: "Selector", current: "r0", shownCurrent: "r0", choices: choices("r", 3)}
            ];
            widget.displayedGroups = ["Foreign", "Russia"];
            widget.stats = [];
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
            assertTrue(widget.groupListHeight("Russia") === 2 * widget.choiceRowHeight,
                "small group height is incorrect");
            widget.expandedGroups = ({Foreign: true, Russia: true});
            const expectedHeight = widget.collapsedGroupsHeight
                + widget.listSeparatorHeight * 2
                + 12 * widget.choiceRowHeight;
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

            widget.applySubscriptionStatus({phase: "error", code: "device_limit", error: "Достигнут лимит устройств Capybara."});
            assertTrue(widget.subscriptionError.indexOf("device limit") >= 0 && !/[А-Яа-яЁё]/.test(widget.subscriptionError),
                "persisted subscription failure is not displayed in English");
            widget.active = true;
            widget.markControllerUnavailable();
            assertTrue(widget.active === false, "controller outage left a stale enabled switch position");
            widget.applyControlResult('{"ok":false,"error":"Test failure"}', 1, "unused");
            assertTrue(widget.active === false && widget.serviceError === "Test failure",
                "failed control action hid its reason or changed the switch");
            widget.applyControlResult('{"ok":true,"active":false,"available":true}', 0, "test");
            assertTrue(widget.active === false && widget.available === true && widget.serviceError === "",
                "confirmed control result was not applied");
            widget.active = true;
            widget.markControllerUnavailable();
            assertTrue(widget.subscriptionError.length > 0, "subscription error disappeared with VPN off");
            widget.applyGroupStates(JSON.parse(JSON.stringify(widget.groupStates)));
            assertTrue(widget.subscriptionError.length > 0, "API refresh cleared subscription error");
            popup = widget.popoutContent.createObject(null, {width: 400});
            assertTrue(popup !== null, "popout content could not be created");
            const notice = findObject(popup, "subscriptionStatusCard");
            assertTrue(notice === null, "subscription error added an unwanted inline card");
            assertTrue(widget.subscriptionTooltip === "Retry subscription update" && widget.indicatorError.length > 0,
                "error tooltip must remain a short action label with a compact indicator");
            assertTrue(widget.groupsContentHeight === expectedHeight, "error status expanded the widget");
            assertTrue(findObject(popup, "subscriptionUpdateButton") !== null, "subscription update button missing");
            widget.applySubscriptionStatus({phase: "success", error: null, node_count: 10, last_success_at: 123});
            assertTrue(widget.subscriptionError === "", "successful retry did not clear subscription error");
            assertTrue(widget.groupsContentHeight === expectedHeight, "successful update changed widget height");
            widget.available = true;
            widget.applySubscriptionStatus({phase: "updating", code: "timeout", error: "Previous attempt timed out"});
            assertTrue(widget.subscriptionBusy && widget.subscriptionTooltip === "Updating subscription…",
                "compact update progress was lost");
            assertTrue(widget.visibleSubscriptionError === "" && widget.indicatorError === "",
                "previous subscription failure leaked into the current update indicator");
            assertTrue(widget.subscriptionError.length > 0, "retry destroyed the stored previous error");
            assertTrue(widget.groupsContentHeight === expectedHeight, "update progress expanded the widget");
            widget.applySubscriptionStatus({phase: "idle", error: null});
            widget.markControllerUnavailable();
            assertTrue(widget.groupsContentHeight === expectedHeight, "idle status changed widget height");
            const vpnSwitch = findObject(popup, "vpnModeSwitch");
            assertTrue(vpnSwitch !== null, "VPN mode switch was not instantiated");
            assertTrue(vpnSwitch.width > 32 && vpnSwitch.radius === vpnSwitch.height / 2,
                "VPN mode switch is not an elongated radio control");
            assertTrue(findObject(popup, "vpnModeToggle").enabled === true,
                "stopped controller disabled the VPN start button");
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
