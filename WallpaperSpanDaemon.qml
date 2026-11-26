import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Modules.Plugins
import "SpanEngine.js" as SpanEngine

PluginComponent {
    id: root

    property var popoutService: null

    readonly property bool isLocked: (typeof IdleService !== "undefined" && IdleService.isShellLocked) ? true : false
    readonly property bool autoSplitExternal: pluginData?.autoSplitExternal === true
    readonly property bool videoPaused: pluginData?.videoPaused === true
    readonly property bool pauseOnNiriColumn: pluginData?.pauseOnNiriColumn !== false
    readonly property int restartIntervalMs: {
        const mins = pluginData?.restartInterval;
        const val = (typeof mins === "number" && !isNaN(mins)) ? mins : 60;
        return val > 0 ? val * 60000 : 0;
    }

    property bool ready: false
    property bool isSyncing: false
    property bool missingMpvWarned: false
    property var previousScreenNames: []
    property var processes: ({})
    property var pendingLaunches: ({})
    property var restartTimers: ({})
    property var recoveryTimers: ({})
    property var stabilityTimers: ({})
    property var recoveryAttempts: ({})
    property var recoveryKeys: ({})
    property var lastStillKeys: ({})
    readonly property int maxRecoveryAttempts: 5

    function isImageFile(path) {
        if (!path || path.startsWith("#"))
            return false;
        if (path.indexOf(SpanController.cacheDir) === 0)
            return false;
        return /\.(jpe?g|png|webp|bmp|gif|jxl|avif|heif)$/i.test(path);
    }

    function isOutputPausedByNiri(monitor) {
        if (!pauseOnNiriColumn || !CompositorService.isNiri || typeof NiriService === "undefined")
            return false;
        return SpanEngine.niriOutputHasColumn(monitor, NiriService.allWorkspaces, NiriService.windows);
    }

    function computeVideoCrops(monitorVideos) {
        const cropsByMon = {};
        const spannedSrc = pluginData?.spannedVideoSource || "";
        const dims = pluginData?.spannedVideoDims || ({});
        const vw = Number(dims?.w) || 0;
        const vh = Number(dims?.h) || 0;
        if (!spannedSrc || vw <= 0 || vh <= 0)
            return cropsByMon;

        const monitors = SpanController.getMonitors(pluginData);
        if (monitors.length < 2)
            return cropsByMon;

        for (let i = 0; i < monitors.length; i++) {
            if (monitorVideos[monitors[i].name] !== spannedSrc)
                return cropsByMon;
        }

        const fitMode = SpanController.fitModeFromData(pluginData);
        const offsets = SpanController.offsetsFromData(pluginData);
        const options = { bezelGapMm: SpanController.bezelGapFromData(pluginData) };
        const crops = SpanEngine.computeSpanCrops(vw, vh, monitors, fitMode, offsets, options);
        for (let j = 0; j < crops.length; j++) {
            cropsByMon[crops[j].name] = SpanEngine.formatMpvCrop(crops[j]);
        }
        return cropsByMon;
    }

    function stopAllVideos() {
        for (const mon in restartTimers)
            stopRestartTimer(mon);
        for (const mon in recoveryTimers) {
            if (recoveryTimers[mon]) {
                recoveryTimers[mon].stop();
                recoveryTimers[mon].destroy();
            }
        }
        recoveryTimers = ({});
        for (const mon in stabilityTimers) {
            if (stabilityTimers[mon]) {
                stabilityTimers[mon].stop();
                stabilityTimers[mon].destroy();
            }
        }
        stabilityTimers = ({});

        for (const mon in processes) {
            if (processes[mon]) {
                processes[mon].stopping = true;
                processes[mon].running = false;
                processes[mon].destroy();
            }
        }
        processes = ({});
        pendingLaunches = ({});
    }

    function stopMpvPaper(monitor, startNew, videoPath, settings, cropGeom, desiredKey) {
        if (processes[monitor]) {
            processes[monitor].stopping = true;
            processes[monitor].running = false;
            processes[monitor].destroy();
            const procs = Object.assign({}, processes);
            delete procs[monitor];
            processes = procs;
        }

        stopRestartTimer(monitor);

        if (startNew && videoPath) {
            const delay = launchDelayComponent.createObject(root, {
                monitor: monitor,
                videoPath: videoPath,
                settings: settings,
                cropGeom: cropGeom || "",
                desiredKey: desiredKey || ""
            });
            delay.start();
        } else {
            const pending = Object.assign({}, pendingLaunches);
            delete pending[monitor];
            pendingLaunches = pending;
        }
    }

    function launchMpvPaper(monitor, videoPath, settings, cropGeom, desiredKey) {
        if (isLocked || videoPaused || !videoPath)
            return;

        if (recoveryKeys[monitor] !== desiredKey) {
            resetRecovery(monitor);
            const keys = Object.assign({}, recoveryKeys);
            keys[monitor] = desiredKey;
            recoveryKeys = keys;
        }

        if (pendingLaunches[monitor])
            return;

        const pending = Object.assign({}, pendingLaunches);
        pending[monitor] = true;
        pendingLaunches = pending;

        stopMpvPaper(monitor, true, videoPath, settings, cropGeom, desiredKey);
        setupRestartTimer(monitor);
    }

    function syncVideosWithData() {
        if (!ready || isSyncing)
            return;

        const monitorVideos = pluginData?.monitorVideos || ({});
        const videoKeys = Object.keys(monitorVideos);

        if (isLocked || videoPaused || videoKeys.length === 0) {
            stopAllVideos();
            return;
        }

        if (!SpanController.capsChecked) {
            SpanController.refreshCapabilities(() => syncDebounce.restart());
            return;
        }

        if (!SpanController.hasMpvpaper) {
            stopAllVideos();
            if (!missingMpvWarned) {
                missingMpvWarned = true;
                console.warn("WallpaperSpan: mpvpaper binary not found; live video playback skipped");
            }
            return;
        }
        missingMpvWarned = false;

        isSyncing = true;
        const connected = Quickshell.screens.map(s => s.name);
        const cropMap = computeVideoCrops(monitorVideos);

        for (const mon in processes) {
            if (!connected.includes(mon) || !monitorVideos[mon])
                stopMpvPaper(mon, false);
        }

        for (let i = 0; i < connected.length; i++) {
            const mon = connected[i];
            const videoPath = monitorVideos[mon] || "";
            if (!videoPath) {
                if (processes[mon])
                    stopMpvPaper(mon, false);
                continue;
            }

            const settings = SpanController.effectiveVideoSettings(pluginData, videoPath);
            const cropGeom = cropMap[mon] || "";

            if (isOutputPausedByNiri(mon)) {
                if (processes[mon] || pendingLaunches[mon])
                    stopMpvPaper(mon, false);
                updateStillAndPalette(mon, videoPath, cropGeom);
                continue;
            }

            const desiredKey = videoPath + "|" + cropGeom + "|" + JSON.stringify(settings);

            const running = processes[mon];
            const needsStart = !running || running.desiredKey !== desiredKey;
            if (needsStart && !pendingLaunches[mon]) {
                launchMpvPaper(mon, videoPath, settings, cropGeom, desiredKey);
            }
        }

        isSyncing = false;
    }

    function setupRestartTimer(monitor) {
        stopRestartTimer(monitor);
        if (restartIntervalMs <= 0)
            return;

        const timer = restartTimerComponent.createObject(root, {
            monitor: monitor,
            interval: restartIntervalMs
        });
        const timers = Object.assign({}, restartTimers);
        timers[monitor] = timer;
        restartTimers = timers;
        timer.start();
    }

    function stopRestartTimer(monitor) {
        if (restartTimers[monitor]) {
            restartTimers[monitor].stop();
            restartTimers[monitor].destroy();
            const timers = Object.assign({}, restartTimers);
            delete timers[monitor];
            restartTimers = timers;
        }
    }

    function scheduleRecovery(monitor, desiredKey) {
        if (recoveryTimers[monitor])
            return;

        if (recoveryKeys[monitor] !== desiredKey) {
            resetRecovery(monitor);
            const keys = Object.assign({}, recoveryKeys);
            keys[monitor] = desiredKey;
            recoveryKeys = keys;
        }

        const attempt = (recoveryAttempts[monitor] || 0) + 1;
        const attempts = Object.assign({}, recoveryAttempts);
        attempts[monitor] = attempt;
        recoveryAttempts = attempts;

        if (attempt > maxRecoveryAttempts) {
            ToastService.showError("Wallpaper Span", "Live wallpaper playback failed on " + monitor);
            return;
        }

        const delay = 1500 * Math.pow(2, attempt - 1);
        const timer = recoveryTimerComponent.createObject(root, {
            monitor: monitor,
            interval: delay
        });
        const timers = Object.assign({}, recoveryTimers);
        timers[monitor] = timer;
        recoveryTimers = timers;
        timer.start();
    }

    function resetRecovery(monitor) {
        if (recoveryTimers[monitor]) {
            recoveryTimers[monitor].stop();
            recoveryTimers[monitor].destroy();
        }
        const timers = Object.assign({}, recoveryTimers);
        const attempts = Object.assign({}, recoveryAttempts);
        const keys = Object.assign({}, recoveryKeys);
        delete timers[monitor];
        delete attempts[monitor];
        delete keys[monitor];
        recoveryTimers = timers;
        recoveryAttempts = attempts;
        recoveryKeys = keys;
    }

    function scheduleStabilityReset(monitor, desiredKey) {
        if (stabilityTimers[monitor]) {
            stabilityTimers[monitor].stop();
            stabilityTimers[monitor].destroy();
        }
        const timer = stabilityTimerComponent.createObject(root, {
            monitor: monitor,
            recoveryKey: desiredKey
        });
        const timers = Object.assign({}, stabilityTimers);
        timers[monitor] = timer;
        stabilityTimers = timers;
        timer.start();
    }

    function updateStillAndPalette(monitor, videoPath, cropGeom) {
        if (pluginData?.videoPaletteSync === false || !SpanController.hasFfmpeg)
            return;

        const key = videoPath + "|" + (cropGeom || "");
        if (lastStillKeys[monitor] === key)
            return;

        const nextKeys = Object.assign({}, lastStillKeys);
        nextKeys[monitor] = key;
        lastStillKeys = nextKeys;

        const cmd = ["bash", SpanController.scriptPath, "video-still", videoPath, SpanController.cacheDir];
        if (cropGeom)
            cmd.push(cropGeom);

        Proc.runCommand("wallpaperSpan.still." + monitor + "." + Date.now(), cmd, (output, exitCode) => {
            if (exitCode !== 0)
                return;
            const stillPath = output.trim().split("\n")[0];
            if (!stillPath)
                return;

            const monitorVideos = pluginData?.monitorVideos || ({});
            if (monitorVideos[monitor] !== videoPath)
                return;

            SpanController.internalApply = true;
            const screens = Quickshell.screens || [];
            const allSameUnspanned = !cropGeom && screens.length > 0 && screens.every(s => monitorVideos[s.name] === videoPath);

            if (allSameUnspanned) {
                const targetMon = (typeof SettingsData !== "undefined" && SettingsData.matugenTargetMonitor) ? SettingsData.matugenTargetMonitor : screens[0].name;
                if (monitor === targetMon) {
                    SessionData.setPerMonitorWallpaper(false);
                    SessionData.setWallpaper(stillPath);
                }
            } else {
                if (!SessionData.perMonitorWallpaper) {
                    const prev = SessionData.wallpaperPath || "";
                    for (let i = 0; i < screens.length; i++) {
                        if (screens[i].name !== monitor && prev && !monitorVideos[screens[i].name]) {
                            SessionData.setMonitorWallpaper(screens[i].name, prev);
                        }
                    }
                    SessionData.setPerMonitorWallpaper(true);
                }
                if (SessionData.getMonitorWallpaperFillMode(monitor) !== "Fill")
                    SessionData.setMonitorWallpaperFillMode(monitor, "Fill");
                SessionData.setMonitorWallpaper(monitor, stillPath);
            }

            Qt.callLater(() => {
                SpanController.internalApply = false;
            });
        });
    }

    onIsLockedChanged: {
        if (isLocked) {
            stopAllVideos();
        } else {
            Qt.callLater(() => {
                if (!isLocked)
                    syncVideosWithData();
            });
        }
    }

    onPluginDataChanged: {
        SpanController.bindPluginService(pluginService);
        if (ready)
            syncDebounce.restart();
    }

    onRestartIntervalMsChanged: {
        if (!ready)
            return;
        for (const mon in processes) {
            if (processes[mon])
                setupRestartTimer(mon);
        }
    }

    Timer {
        id: syncDebounce
        interval: 60
        repeat: false
        onTriggered: root.syncVideosWithData()
    }

    Component {
        id: mpvProcessComponent

        Process {
            id: mpvProc

            property string monitor: ""
            property string videoPath: ""
            property var settings: ({})
            property string cropGeom: ""
            property string desiredKey: ""
            property bool stopping: false

            command: SpanEngine.buildMpvArgs(monitor, videoPath, settings, cropGeom)

            onExited: (code) => {
                const procs = Object.assign({}, root.processes);
                if (procs[monitor] === mpvProc) {
                    delete procs[monitor];
                    root.processes = procs;
                }

                const activeVideos = root.pluginData?.monitorVideos || ({});
                if (!stopping && !root.isLocked && !root.videoPaused && !root.isOutputPausedByNiri(monitor) && activeVideos[monitor] === videoPath) {
                    if (code !== 0)
                        console.warn("WallpaperSpan: mpvpaper exited with code", code, "on", monitor);
                    root.scheduleRecovery(monitor, desiredKey);
                }
            }
        }
    }

    Component {
        id: launchDelayComponent

        Timer {
            property string monitor: ""
            property string videoPath: ""
            property var settings: ({})
            property string cropGeom: ""
            property string desiredKey: ""
            interval: 150
            repeat: false

            onTriggered: {
                const pending = Object.assign({}, root.pendingLaunches);
                const activeVideos = root.pluginData?.monitorVideos || ({});
                if (!root.isLocked && !root.videoPaused && !root.isOutputPausedByNiri(monitor) && videoPath && activeVideos[monitor] === videoPath) {
                    const proc = mpvProcessComponent.createObject(root, {
                        monitor: monitor,
                        videoPath: videoPath,
                        settings: settings,
                        cropGeom: cropGeom,
                        desiredKey: desiredKey
                    });
                    const procs = Object.assign({}, root.processes);
                    procs[monitor] = proc;
                    root.processes = procs;
                    proc.running = true;
                    root.scheduleStabilityReset(monitor, desiredKey);
                    root.updateStillAndPalette(monitor, videoPath, cropGeom);
                }
                delete pending[monitor];
                root.pendingLaunches = pending;
                destroy();
            }
        }
    }

    Component {
        id: restartTimerComponent

        Timer {
            property string monitor: ""
            repeat: false
            onTriggered: {
                const activeVideos = root.pluginData?.monitorVideos || ({});
                const vp = activeVideos[monitor] || "";
                if (!root.isLocked && !root.videoPaused && !root.isOutputPausedByNiri(monitor) && vp) {
                    const settings = SpanController.effectiveVideoSettings(root.pluginData, vp);
                    const cropMap = root.computeVideoCrops(activeVideos);
                    const cg = cropMap[monitor] || "";
                    const key = vp + "|" + cg + "|" + JSON.stringify(settings);
                    root.launchMpvPaper(monitor, vp, settings, cg, key);
                }
            }
        }
    }

    Component {
        id: recoveryTimerComponent

        Timer {
            property string monitor: ""
            interval: 1500
            repeat: false
            onTriggered: {
                const timers = Object.assign({}, root.recoveryTimers);
                delete timers[monitor];
                root.recoveryTimers = timers;
                destroy();
                if (!root.isLocked && !root.videoPaused)
                    root.syncVideosWithData();
            }
        }
    }

    Component {
        id: stabilityTimerComponent

        Timer {
            property string monitor: ""
            property string recoveryKey: ""
            interval: 30000
            repeat: false
            onTriggered: {
                const timers = Object.assign({}, root.stabilityTimers);
                delete timers[monitor];
                root.stabilityTimers = timers;
                destroy();
                if (root.recoveryKeys[monitor] === recoveryKey && root.processes[monitor]) {
                    const attempts = Object.assign({}, root.recoveryAttempts);
                    delete attempts[monitor];
                    root.recoveryAttempts = attempts;
                }
            }
        }
    }

    Connections {
        target: NiriService
        enabled: CompositorService.isNiri && root.pauseOnNiriColumn

        function onAllWorkspacesChanged() {
            if (root.ready)
                syncDebounce.restart();
        }

        function onWindowsChanged() {
            if (root.ready)
                syncDebounce.restart();
        }

        function onOutputsChanged() {
            if (root.ready)
                syncDebounce.restart();
        }
    }

    Connections {
        target: Quickshell

        function onScreensChanged() {
            const currentNames = Quickshell.screens.map(s => s.name);
            for (let i = 0; i < root.previousScreenNames.length; i++) {
                const oldName = root.previousScreenNames[i];
                if (!currentNames.includes(oldName) && root.processes[oldName])
                    root.stopMpvPaper(oldName, false);
            }
            root.previousScreenNames = currentNames;
            syncDebounce.restart();
        }
    }

    Connections {
        target: SessionData

        function onWallpaperPathChanged() {
            if (!root.autoSplitExternal || SpanController.internalApply)
                return;
            const path = SessionData.wallpaperPath || "";
            if (!root.isImageFile(path))
                return;
            const monitors = SpanController.getMonitors(root.pluginData);
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

        function stopVideo(screenName: string): string {
            SpanController.stopVideos(screenName ? [screenName] : null);
            return "ok";
        }

        function togglePause(): string {
            const paused = !(root.pluginData?.videoPaused === true);
            SpanController.setVideosPaused(paused);
            return paused ? "paused" : "playing";
        }

        function clearCache(): string {
            SpanController.clearCache();
            return "ok";
        }
    }

    Component.onCompleted: {
        SpanController.bindPluginService(pluginService);
        previousScreenNames = Quickshell.screens.map(s => s.name);
        ready = true;
        SpanController.refreshCapabilities(() => syncVideosWithData());
    }

    Component.onDestruction: {
        stopAllVideos();
    }
}
