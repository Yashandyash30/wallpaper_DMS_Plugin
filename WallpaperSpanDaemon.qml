import QtQuick
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Modules.Plugins

PluginComponent {
    id: root

    property var popoutService: null

    readonly property bool autoSplitExternal: pluginData.autoSplitExternal === true

    function isImageFile(path) {
        if (!path || path.startsWith("#"))
            return false;
        if (path.indexOf(SpanController.cacheDir) === 0)
            return false;
        return /\.(jpe?g|png|webp|bmp|gif|jxl|avif|heif)$/i.test(path);
    }

    Connections {
        target: SessionData

        function onWallpaperPathChanged() {
            if (!root.autoSplitExternal || SpanController.internalApply)
                return;
            const path = SessionData.wallpaperPath || "";
            if (!root.isImageFile(path))
                return;
            const monitors = SpanController.getMonitors();
            if (monitors.length < 2)
                return;

            SpanController.probeDimensions(path, (w, h) => {
                if (SpanController.internalApply)
                    return;
                const threshold = SpanController.thresholdFromData(root.pluginData);
                if (w > 0 && h > 0 && (w / h) >= threshold) {
                    SpanController.applySpan(path, w, h, root.pluginData);
                }
            });
        }
    }

    IpcHandler {
        target: "wallpaperSpan"

        function apply(path: string): string {
            if (!path)
                return "error: path required";
            SpanController.applyAuto(path, 0, 0, root.pluginData);
            return "ok";
        }

        function span(path: string): string {
            if (!path)
                return "error: path required";
            SpanController.applySpan(path, 0, 0, root.pluginData);
            return "ok";
        }

        function same(path: string): string {
            if (!path)
                return "error: path required";
            SpanController.applySameOnAll(path);
            return "ok";
        }

        function setMonitor(screenName: string, path: string): string {
            if (!screenName || !path)
                return "error: screenName and path required";
            SpanController.applyToMonitor(screenName, path);
            return "ok";
        }

        function clearCache(): string {
            SpanController.clearCache();
            return "ok";
        }
    }
}
