import QtQuick
import QtTest
import Quickshell
import qs.Common
import "plugin" as Mihomo

ShellRoot {
    QtObject {
        id: service
        property var groups: ["Foreign", "Russia"]
        signal pluginDataChanged(string pluginId)
        function getPluginVariants(pluginId) { return []; }
        function loadPluginData(pluginId, key, fallback) {
            return key === "visibleGroups" ? groups : fallback;
        }
        function savePluginData(pluginId, key, value) {
            if (key === "visibleGroups")
                groups = value.slice();
        }
    }

    FloatingWindow {
        id: testWindow
        visible: true
        implicitWidth: 540
        implicitHeight: 400
        title: "Mihomo settings interaction test"
        color: Theme.surface

        Mihomo.MihomoVpnSettings {
            id: settings
            x: 16
            y: 16
            width: parent.width - 32
            pluginService: service
            function loadGroups() {
                availableGroups = ["GLOBAL", "Foreign", "Russia"].map(name => ({name: name, type: "Selector"}));
                loadSavedGroups();
            }
        }

        TestCase {
            name: "MihomoSettings"
            when: testWindow.visible

            function test_dragAndToggle() {
                wait(100);
                const foreign = findChild(settings, "settingsGroup:Foreign");
                const russia = findChild(settings, "settingsGroup:Russia");
                const global = findChild(settings, "settingsGroup:GLOBAL");
                verify(foreign !== null && russia !== null && global !== null);
                mouseDrag(foreign, 100, 18, 0, settings.groupRowStep);
                compare(service.groups, ["Russia", "Foreign"]);
                verify(russia.mapToItem(settings, 0, 0).y < foreign.mapToItem(settings, 0, 0).y);
                mouseDrag(foreign, 100, 18, 0, -settings.groupRowStep);
                compare(service.groups, ["Foreign", "Russia"]);
                mouseClick(foreign, 100, 18);
                compare(service.groups, ["Russia"]);
                verify(foreign.mapToItem(settings, 0, 0).y > russia.mapToItem(settings, 0, 0).y);
                mouseClick(global, 100, 18);
                compare(service.groups, ["Russia", "GLOBAL"]);
                verify(global.mapToItem(settings, 0, 0).y < foreign.mapToItem(settings, 0, 0).y);
                console.warn("MIHOMO_SETTINGS_SELFTEST_PASS drag-up drag-down click-toggle disabled-last");
            }
        }
    }
}
