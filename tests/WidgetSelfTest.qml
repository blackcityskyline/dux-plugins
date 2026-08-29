import QtQuick
import Quickshell
import qs.Common
import "plugin" as Mihomo

ShellRoot {
    id: shell

    property var widget: null
    property var popup: null
    property var longList: null

    Component {
        id: widgetComponent
        Mihomo.MihomoVpnWidget {}
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
            assertTrue(Math.abs(longList.contentY - 120) < 1,
                "long-list scroll position was reset by an identical refresh");
            assertTrue(popup.implicitHeight === widget.popoutHeaderHeight + widget.groupsViewportHeight,
                "content implicitHeight does not match calculated viewport height");
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
            widget = widgetComponent.createObject(null);
            assertTrue(widget !== null, "widget could not be created");
            assertTrue(widget.helper.endsWith("/plugin/mihomo-dms"),
                "widget helper does not resolve inside the plugin directory");
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

            popup = widget.popoutContent.createObject(null, {width: 400});
            assertTrue(popup !== null, "popout content could not be created");
            const vpnSwitch = findObject(popup, "vpnModeSwitch");
            assertTrue(vpnSwitch !== null, "VPN mode switch was not instantiated");
            assertTrue(vpnSwitch.width > 32 && vpnSwitch.radius === vpnSwitch.height / 2,
                "VPN mode switch is not an elongated radio control");
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
