pragma Singleton

import QtQuick
import Quickshell
import qs.Common
import qs.Services
import "SpanEngine.js" as SpanEngine

Singleton {
    id: root

    readonly property string scriptPath: Paths.strip(Qt.resolvedUrl("scripts/span.sh"))
    readonly property string cacheDir: Paths.strip(Paths.cache) + "/wallpaperSpan"

    property bool busy: false
    property bool internalApply: false
    property string lastSpannedSource: ""

    signal applied(string mode, string sourcePath)

    function getMonitors(pluginData) {
        const screens = Quickshell.screens || [];
        const isNiri = CompositorService.isNiri;
        const niriOutputs = (typeof NiriService !== "undefined" && NiriService.outputs) ? NiriService.outputs : {};
        const isHyprland = CompositorService.isHyprland;
        const hyprMonitors = (isHyprland && typeof Hyprland !== "undefined" && Hyprland.monitors?.values) ? Hyprland.monitors.values : [];
        const diagonals = (pluginData && typeof pluginData.monitorDiagonals === "object" && pluginData.monitorDiagonals !== null) ? pluginData.monitorDiagonals : ({});
        return SpanEngine.resolveMonitors(screens, isNiri, niriOutputs, isHyprland, hyprMonitors, diagonals);
    }

    function thresholdFromData(data) {
        const pct = Number(data?.wideThresholdPercent);
        return (!isNaN(pct) && pct >= 120) ? pct / 100.0 : 2.2;
    }

    function fitModeFromData(data) {
        if (data?.spanFitMode === "equal")
            return "equal";
        if (data?.spanFitMode === "cover")
            return "cover";
        return "physical";
    }

    function bezelGapFromData(data) {
        const gap = Number(data?.bezelGapMm);
        return (!isNaN(gap) && gap >= 0) ? gap : 0;
    }

    function offsetsFromData(data) {
        return (data && typeof data.monitorOffsets === "object" && data.monitorOffsets !== null) ? data.monitorOffsets : ({});
    }

    function _releaseInternalGuard() {
        Qt.callLater(() => {
            root.internalApply = false;
        });
    }

    function applySameOnAll(imagePath) {
        if (!imagePath)
            return;
        internalApply = true;
        lastSpannedSource = "";
        SessionData.setPerMonitorWallpaper(false);
        SessionData.setWallpaper(imagePath);
        applied("same", imagePath);
        _releaseInternalGuard();
    }

    function applyToMonitor(screenName, imagePath) {
        if (!screenName || !imagePath)
            return;
        internalApply = true;
        lastSpannedSource = "";
        if (!SessionData.perMonitorWallpaper) {
            const prev = SessionData.wallpaperPath || "";
            const monitors = getMonitors(pluginData);
            for (let i = 0; i < monitors.length; i++) {
                if (monitors[i].name !== screenName && prev) {
                    SessionData.setMonitorWallpaper(monitors[i].name, prev);
                }
            }
            SessionData.setPerMonitorWallpaper(true);
        }
        SessionData.setMonitorWallpaper(screenName, imagePath);
        applied("single", imagePath);
        _releaseInternalGuard();
    }

    function probeDimensions(imagePath, callback) {
        Proc.runCommand("wallpaperSpan.probe." + Date.now(), ["bash", scriptPath, "probe", imagePath], (output, exitCode) => {
            if (exitCode !== 0) {
                callback(0, 0);
                return;
            }
            const parts = output.trim().split("\t");
            const w = parseInt(parts[0], 10) || 0;
            const h = parseInt(parts[1], 10) || 0;
            callback(w, h);
        });
    }

    function applySpan(imagePath, imgW, imgH, pluginData, doneCallback) {
        if (!imagePath) {
            if (doneCallback)
                doneCallback(false);
            return;
        }

        const monitors = getMonitors(pluginData);
        if (monitors.length < 2) {
            ToastService.showInfo("Wallpaper Span", "Only 1 monitor detected — applied normally");
            applySameOnAll(imagePath);
            if (doneCallback)
                doneCallback(true);
            return;
        }

        if (!imgW || !imgH || imgW <= 0 || imgH <= 0) {
            probeDimensions(imagePath, (pw, ph) => {
                if (pw <= 0 || ph <= 0) {
                    ToastService.showError("Wallpaper Span", "Could not read image dimensions");
                    if (doneCallback)
                        doneCallback(false);
                    return;
                }
                applySpan(imagePath, pw, ph, pluginData, doneCallback);
            });
            return;
        }

        const fitMode = fitModeFromData(pluginData);
        const offsets = offsetsFromData(pluginData);
        const options = { bezelGapMm: bezelGapFromData(pluginData) };
        const crops = SpanEngine.computeSpanCrops(imgW, imgH, monitors, fitMode, offsets, options);
        if (crops.length === 0) {
            if (doneCallback)
                doneCallback(false);
            return;
        }

        const sig = SpanEngine.layoutSignature(monitors, fitMode, offsets, options);
        const cmd = ["bash", scriptPath, "split", imagePath, cacheDir, sig];
        for (let i = 0; i < crops.length; i++) {
            const c = crops[i];
            cmd.push(`${c.name}:${c.w}x${c.h}+${c.x}+${c.y}`);
        }

        busy = true;
        Proc.runCommand("wallpaperSpan.split", cmd, (output, exitCode) => {
            busy = false;
            if (exitCode !== 0) {
                ToastService.showError("Wallpaper Span", output.trim() || "Failed to split wallpaper");
                if (doneCallback)
                    doneCallback(false);
                return;
            }

            const lines = output.trim().split("\n").filter(l => l.length > 0);
            if (lines.length === 0) {
                if (doneCallback)
                    doneCallback(false);
                return;
            }

            internalApply = true;
            SessionData.setPerMonitorWallpaper(true);
            for (let i = 0; i < lines.length; i++) {
                const tabIdx = lines[i].indexOf("\t");
                if (tabIdx <= 0)
                    continue;
                const screenName = lines[i].slice(0, tabIdx);
                const slicePath = lines[i].slice(tabIdx + 1).trim();
                if (SessionData.getMonitorWallpaperFillMode(screenName) !== "Fill") {
                    SessionData.setMonitorWallpaperFillMode(screenName, "Fill");
                }
                SessionData.setMonitorWallpaper(screenName, slicePath);
            }
            lastSpannedSource = imagePath;
            ToastService.showInfo("Wallpaper Span", `Spanned across ${lines.length} displays`);
            applied("span", imagePath);
            _releaseInternalGuard();
            if (doneCallback)
                doneCallback(true);
        });
    }

    function applyAuto(imagePath, imgW, imgH, pluginData, doneCallback) {
        if (!imagePath) {
            if (doneCallback)
                doneCallback(false);
            return;
        }

        const monitors = getMonitors(pluginData);
        const autoSplit = pluginData?.autoSplitWide !== false;
        if (monitors.length < 2 || !autoSplit) {
            applySameOnAll(imagePath);
            if (doneCallback)
                doneCallback(true);
            return;
        }

        if (!imgW || !imgH || imgW <= 0 || imgH <= 0) {
            probeDimensions(imagePath, (pw, ph) => {
                if (pw <= 0 || ph <= 0) {
                    applySameOnAll(imagePath);
                    if (doneCallback)
                        doneCallback(true);
                    return;
                }
                applyAuto(imagePath, pw, ph, pluginData, doneCallback);
            });
            return;
        }

        const threshold = thresholdFromData(pluginData);
        if (SpanEngine.isWideImage(imgW, imgH, threshold)) {
            applySpan(imagePath, imgW, imgH, pluginData, doneCallback);
        } else {
            applySameOnAll(imagePath);
            if (doneCallback)
                doneCallback(true);
        }
    }

    function clearCache(doneCallback) {
        Proc.runCommand("wallpaperSpan.clearCache", ["bash", scriptPath, "clear-cache", cacheDir], (output, exitCode) => {
            if (exitCode === 0) {
                ToastService.showInfo("Wallpaper Span", "Cleared split wallpaper cache");
            } else {
                ToastService.showError("Wallpaper Span", output.trim() || "Failed to clear cache");
            }
            if (doneCallback)
                doneCallback(exitCode === 0);
        });
    }
}
