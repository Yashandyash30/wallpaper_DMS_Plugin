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
    readonly property string pluginId: "wallpaperSpan"

    property var pluginServiceRef: null
    property bool busy: false
    property bool internalApply: false
    property string lastSpannedSource: ""

    property bool capsChecked: false
    property bool hasMpvpaper: false
    property bool hasFfmpeg: false
    property bool hasFfprobe: false

    signal applied(string mode, string sourcePath)

    function bindPluginService(ps) {
        if (ps && pluginServiceRef !== ps)
            pluginServiceRef = ps;
        if (!capsChecked || !hasMpvpaper)
            refreshCapabilities();
    }

    function refreshCapabilities(callback) {
        Proc.runCommand("wallpaperSpan.caps." + Date.now(), ["bash", scriptPath, "caps"], (output, exitCode) => {
            if (exitCode === 0) {
                const text = output.trim();
                hasMpvpaper = text.indexOf("mpvpaper=1") >= 0;
                hasFfmpeg = text.indexOf("ffmpeg=1") >= 0;
                hasFfprobe = text.indexOf("ffprobe=1") >= 0;
                capsChecked = true;
            }
            if (callback)
                callback(hasMpvpaper, hasFfmpeg, hasFfprobe);
        });
    }

    function _saveData(key, value) {
        if (pluginServiceRef && pluginServiceRef.savePluginData)
            pluginServiceRef.savePluginData(pluginId, key, value);
    }

    function _loadData(key, fallback) {
        if (pluginServiceRef && pluginServiceRef.loadPluginData) {
            const v = pluginServiceRef.loadPluginData(pluginId, key, fallback);
            return v === undefined ? fallback : v;
        }
        return fallback;
    }

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

    function effectiveVideoSettings(pluginData, videoPath) {
        const data = pluginData || ({});
        const all = (data.videoSettings && typeof data.videoSettings === "object") ? data.videoSettings : ({});
        const per = (videoPath && all[videoPath] && typeof all[videoPath] === "object") ? all[videoPath] : ({});
        const parsedPanscan = (data.defaultPanscan !== undefined && data.defaultPanscan !== null && data.defaultPanscan !== "")
            ? Number(data.defaultPanscan)
            : NaN;
        const defPanscan = Number.isFinite(parsedPanscan) ? parsedPanscan : 1.0;
        const parsedVol = (data.defaultVolume !== undefined && data.defaultVolume !== null && data.defaultVolume !== "")
            ? Number(data.defaultVolume)
            : NaN;
        const defVol = Number.isFinite(parsedVol) ? parsedVol : 0;
        return {
            hwdec: per.hwdec || data.defaultHwdec || "auto",
            panscan: (per.panscan !== undefined && per.panscan !== null && per.panscan !== "") ? Number(per.panscan) : defPanscan,
            volume: (per.volume !== undefined && per.volume !== null && per.volume !== "") ? Number(per.volume) : defVol
        };
    }

    function updateVideoSetting(videoPath, key, value, pluginData) {
        if (!videoPath || !pluginServiceRef)
            return;
        const stored = _loadData("videoSettings", pluginData?.videoSettings || {});
        const all = Object.assign({}, stored || {});
        const entry = Object.assign({}, all[videoPath] || {});
        entry[key] = value;
        all[videoPath] = entry;
        _saveData("videoSettings", all);
    }

    function _releaseInternalGuard() {
        Qt.callLater(() => {
            root.internalApply = false;
        });
    }

    function _clearMonitorVideos(screenNames) {
        const prev = _loadData("monitorVideos", {});
        const next = Object.assign({}, prev || {});
        let changed = false;

        if (!screenNames) {
            if (Object.keys(next).length > 0) {
                _saveData("monitorVideos", ({}));
                changed = true;
            }
        } else {
            for (let i = 0; i < screenNames.length; i++) {
                if (next.hasOwnProperty(screenNames[i])) {
                    delete next[screenNames[i]];
                    changed = true;
                }
            }
            if (changed)
                _saveData("monitorVideos", next);
        }

        const spanned = _loadData("spannedVideoSource", "");
        if (spanned && (!screenNames || Object.keys(next).length < 2)) {
            _saveData("spannedVideoSource", "");
            _saveData("spannedVideoDims", ({}));
        }
    }

    function stopVideos(screenNames) {
        _clearMonitorVideos(screenNames || null);
        _saveData("videoPaused", false);
    }

    function setVideosPaused(paused) {
        _saveData("videoPaused", !!paused);
    }

    function _withMpvpaper(onReady) {
        if (hasMpvpaper) {
            onReady();
            return;
        }
        refreshCapabilities((mpvOk) => {
            if (mpvOk) {
                onReady();
            } else {
                ToastService.showError("Install mpvpaper to play live wallpapers", "sudo pacman -S mpvpaper");
            }
        });
    }

    function _applyVideoAll(videoPath, spanned, imgW, imgH) {
        const monitors = getMonitors({ monitorDiagonals: _loadData("monitorDiagonals", {}) });
        if (monitors.length === 0)
            return false;

        _withMpvpaper(() => {
            const nextVideos = {};
            for (let i = 0; i < monitors.length; i++)
                nextVideos[monitors[i].name] = videoPath;

            _saveData("videoPaused", false);
            if (spanned && imgW > 0 && imgH > 0) {
                _saveData("spannedVideoSource", videoPath);
                _saveData("spannedVideoDims", { w: imgW, h: imgH });
                lastSpannedSource = videoPath;
            } else {
                _saveData("spannedVideoSource", "");
                _saveData("spannedVideoDims", ({}));
                lastSpannedSource = "";
            }
            _saveData("monitorVideos", nextVideos);
            applied(spanned ? "span" : "same", videoPath);
        });
        return true;
    }

    function applySameOnAll(mediaPath) {
        if (!mediaPath)
            return;
        if (SpanEngine.isVideoPath(mediaPath)) {
            _applyVideoAll(mediaPath, false, 0, 0);
            return;
        }
        _clearMonitorVideos(null);
        internalApply = true;
        lastSpannedSource = "";
        SessionData.setPerMonitorWallpaper(false);
        SessionData.setWallpaper(mediaPath);
        applied("same", mediaPath);
        _releaseInternalGuard();
    }

    function applyToMonitor(screenName, mediaPath) {
        if (!screenName || !mediaPath)
            return;
        if (SpanEngine.isVideoPath(mediaPath)) {
            _withMpvpaper(() => {
                const prev = _loadData("monitorVideos", {});
                const next = Object.assign({}, prev || {});
                next[screenName] = mediaPath;
                _saveData("videoPaused", false);
                _saveData("spannedVideoSource", "");
                _saveData("spannedVideoDims", ({}));
                _saveData("monitorVideos", next);
                lastSpannedSource = "";
                applied("single", mediaPath);
            });
            return;
        }

        _clearMonitorVideos([screenName]);
        internalApply = true;
        lastSpannedSource = "";
        if (!SessionData.perMonitorWallpaper) {
            const prev = SessionData.wallpaperPath || "";
            const monitors = getMonitors({ monitorDiagonals: _loadData("monitorDiagonals", {}) });
            for (let i = 0; i < monitors.length; i++) {
                if (monitors[i].name !== screenName && prev) {
                    SessionData.setMonitorWallpaper(monitors[i].name, prev);
                }
            }
            SessionData.setPerMonitorWallpaper(true);
        }
        SessionData.setMonitorWallpaper(screenName, mediaPath);
        applied("single", mediaPath);
        _releaseInternalGuard();
    }

    function probeDimensions(mediaPath, callback) {
        Proc.runCommand("wallpaperSpan.probe." + Date.now(), ["bash", scriptPath, "probe", mediaPath], (output, exitCode) => {
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

    function applySpan(mediaPath, imgW, imgH, pluginData, doneCallback) {
        if (!mediaPath) {
            if (doneCallback)
                doneCallback(false);
            return;
        }

        const isVideo = SpanEngine.isVideoPath(mediaPath);
        const monitors = getMonitors(pluginData);
        if (monitors.length < 2) {
            ToastService.showInfo("Only 1 monitor detected — applied normally");
            applySameOnAll(mediaPath);
            if (doneCallback)
                doneCallback(true);
            return;
        }

        if (!imgW || !imgH || imgW <= 0 || imgH <= 0) {
            probeDimensions(mediaPath, (pw, ph) => {
                if (pw <= 0 || ph <= 0) {
                    if (isVideo) {
                        ToastService.showInfo("Video resolution unknown — playing uniformly");
                        applySameOnAll(mediaPath);
                        if (doneCallback)
                            doneCallback(true);
                    } else {
                        ToastService.showError("Could not read image dimensions");
                        if (doneCallback)
                            doneCallback(false);
                    }
                    return;
                }
                applySpan(mediaPath, pw, ph, pluginData, doneCallback);
            });
            return;
        }

        if (isVideo) {
            const ok = _applyVideoAll(mediaPath, true, imgW, imgH);
            if (ok)
                ToastService.showInfo(`Spanning live wallpaper across ${monitors.length} displays`);
            if (doneCallback)
                doneCallback(ok);
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
        const cmd = ["bash", scriptPath, "split", mediaPath, cacheDir, sig];
        for (let i = 0; i < crops.length; i++) {
            const c = crops[i];
            cmd.push(`${c.name}:${c.w}x${c.h}+${c.x}+${c.y}`);
        }

        busy = true;
        Proc.runCommand("wallpaperSpan.split", cmd, (output, exitCode) => {
            busy = false;
            if (exitCode !== 0) {
                ToastService.showError("Failed to split wallpaper", output.trim());
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

            _clearMonitorVideos(null);
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
            lastSpannedSource = mediaPath;
            ToastService.showInfo(`Spanned across ${lines.length} displays`);
            applied("span", mediaPath);
            _releaseInternalGuard();
            if (doneCallback)
                doneCallback(true);
        });
    }

    function applyAuto(mediaPath, imgW, imgH, pluginData, doneCallback) {
        if (!mediaPath) {
            if (doneCallback)
                doneCallback(false);
            return;
        }

        const monitors = getMonitors(pluginData);
        const autoSplit = pluginData?.autoSplitWide !== false;
        if (monitors.length < 2 || !autoSplit) {
            applySameOnAll(mediaPath);
            if (doneCallback)
                doneCallback(true);
            return;
        }

        if (!imgW || !imgH || imgW <= 0 || imgH <= 0) {
            probeDimensions(mediaPath, (pw, ph) => {
                if (pw <= 0 || ph <= 0) {
                    applySameOnAll(mediaPath);
                    if (doneCallback)
                        doneCallback(true);
                    return;
                }
                applyAuto(mediaPath, pw, ph, pluginData, doneCallback);
            });
            return;
        }

        const threshold = thresholdFromData(pluginData);
        if (SpanEngine.isWideImage(imgW, imgH, threshold)) {
            applySpan(mediaPath, imgW, imgH, pluginData, doneCallback);
        } else {
            applySameOnAll(mediaPath);
            if (doneCallback)
                doneCallback(true);
        }
    }

    function clearCache(doneCallback) {
        Proc.runCommand("wallpaperSpan.clearCache", ["bash", scriptPath, "clear-cache", cacheDir], (output, exitCode) => {
            if (exitCode === 0) {
                ToastService.showInfo("Cleared wallpaper span & thumbnail cache");
            } else {
                ToastService.showError("Failed to clear cache", output.trim());
            }
            if (doneCallback)
                doneCallback(exitCode === 0);
        });
    }
}
