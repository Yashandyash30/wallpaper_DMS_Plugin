pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Common
import qs.DCommon.Widgets
import qs.Modals.FileBrowser
import qs.Services
import "SpanEngine.js" as SpanEngine

Item {
    id: root

    property var pluginService: null
    property var pluginData: ({})
    property string pluginId: "wallpaperSpan"
    property var slideoutRef: null

    property string selectedTarget: "all"
    property string filterMode: "all"
    property string searchQuery: ""
    property bool scanning: false
    property bool showAlignBar: false
    property var localOffsets: ({})
    property int localBezelGapMm: 0
    property var monitors: []
    property var allItems: []
    property int wideCount: 0
    property int normalCount: 0
    property int liveCount: 0
    property var thumbMap: ({})
    property var thumbQueue: []
    property int activeThumbJobs: 0
    property int thumbJobSeq: 0

    readonly property string configuredDir: pluginData?.wallpaperDir || "~/Pictures/Wallpapers"
    readonly property string resolvedDir: Paths.expandTilde(configuredDir)
    readonly property bool recursiveScan: pluginData?.recursive !== false
    readonly property bool autoSplitWide: pluginData?.autoSplitWide !== false
    readonly property real wideThreshold: SpanController.thresholdFromData(pluginData)
    readonly property var monitorVideos: pluginData?.monitorVideos || ({})
    readonly property bool videoPaused: pluginData?.videoPaused === true
    readonly property bool pauseOnNiriColumn: pluginData?.pauseOnNiriColumn !== false
    readonly property string spannedVideoSource: pluginData?.spannedVideoSource || ""
    readonly property string activeLivePath: activeTargetVideo()

    function isNiriColumnPaused(screenName) {
        if (!pauseOnNiriColumn || !CompositorService.isNiri || typeof NiriService === "undefined")
            return false;
        return SpanEngine.niriOutputHasColumn(screenName, NiriService.allWorkspaces, NiriService.windows);
    }

    function anyTargetNiriPaused() {
        if (selectedTarget !== "all")
            return isNiriColumnPaused(selectedTarget);
        for (let i = 0; i < monitors.length; i++) {
            if (monitorVideos?.[monitors[i].name] && isNiriColumnPaused(monitors[i].name))
                return true;
        }
        return false;
    }
    readonly property var effectivePluginData: Object.assign({}, pluginData || {}, {
        monitorOffsets: localOffsets,
        bezelGapMm: localBezelGapMm
    })

    ListModel {
        id: filteredModel
    }

    function refreshMonitors() {
        monitors = SpanController.getMonitors(effectivePluginData);
        if (selectedTarget !== "all" && !monitors.some(m => m.name === selectedTarget)) {
            selectedTarget = "all";
        }
    }

    function saveSetting(key, value) {
        if (!pluginService || !pluginId)
            return;
        pluginService.savePluginData(pluginId, key, value);
    }

    function scanFolder() {
        const dir = resolvedDir;
        if (!dir)
            return;
        scanning = true;
        Proc.runCommand("wallpaperSpan.scan", ["bash", SpanController.scriptPath, "scan", dir, recursiveScan ? "1" : "0"], (output, exitCode) => {
            scanning = false;
            if (exitCode !== 0) {
                ToastService.showError("Failed to scan wallpaper folder");
                allItems = [];
                rebuildFiltered();
                return;
            }
            const parsed = [];
            const lines = output.split("\n");
            for (let i = 0; i < lines.length; i++) {
                const line = lines[i].trim();
                if (!line)
                    continue;
                const t1 = line.indexOf("\t");
                const t2 = t1 >= 0 ? line.indexOf("\t", t1 + 1) : -1;
                const t3 = t2 >= 0 ? line.indexOf("\t", t2 + 1) : -1;
                if (t1 <= 0 || t2 <= t1 || t3 <= t2)
                    continue;
                const mediaType = line.slice(0, t1);
                const w = parseInt(line.slice(t1 + 1, t2), 10) || 0;
                const h = parseInt(line.slice(t2 + 1, t3), 10) || 0;
                const path = line.slice(t3 + 1);
                const slash = path.lastIndexOf("/");
                const name = slash >= 0 ? path.slice(slash + 1) : path;
                parsed.push({
                    mediaType: mediaType === "video" ? "video" : "image",
                    path: path,
                    name: name,
                    width: w,
                    height: h,
                    aspect: SpanEngine.formatAspectLabel(w, h)
                });
            }
            allItems = parsed;
            recountTypes();
            rebuildFiltered();
        });
    }

    function recountTypes() {
        let wCount = 0;
        let nCount = 0;
        let lCount = 0;
        const threshold = wideThreshold;
        for (let i = 0; i < allItems.length; i++) {
            if (allItems[i].mediaType === "video")
                lCount++;
            if (SpanEngine.isWideImage(allItems[i].width, allItems[i].height, threshold))
                wCount++;
            else
                nCount++;
        }
        wideCount = wCount;
        normalCount = nCount;
        liveCount = lCount;
    }

    function rebuildFiltered() {
        filteredModel.clear();
        const q = searchQuery.trim().toLowerCase();
        const threshold = wideThreshold;

        for (let i = 0; i < allItems.length; i++) {
            const it = allItems[i];
            const isWide = SpanEngine.isWideImage(it.width, it.height, threshold);

            if (filterMode === "wide" && !isWide)
                continue;
            if (filterMode === "normal" && isWide)
                continue;
            if (filterMode === "live" && it.mediaType !== "video")
                continue;
            if (q && it.name.toLowerCase().indexOf(q) === -1 && it.path.toLowerCase().indexOf(q) === -1)
                continue;

            filteredModel.append({
                mediaType: it.mediaType,
                path: it.path,
                name: it.name,
                imgWidth: it.width,
                imgHeight: it.height,
                aspect: it.aspect,
                isWide: isWide,
                thumbPath: thumbMap[it.path] || ""
            });
        }
    }

    function requestVideoThumb(videoPath) {
        if (!videoPath || thumbMap[videoPath] || (SpanController.capsChecked && !SpanController.hasFfmpeg))
            return;
        if (thumbQueue.indexOf(videoPath) !== -1)
            return;
        const next = thumbQueue.slice();
        next.push(videoPath);
        thumbQueue = next;
        drainThumbQueue();
    }

    function drainThumbQueue() {
        if (!SpanController.capsChecked || !SpanController.hasFfmpeg)
            return;
        while (activeThumbJobs < 2 && thumbQueue.length > 0) {
            const next = thumbQueue.slice();
            const vp = next.shift();
            thumbQueue = next;
            if (!vp || thumbMap[vp])
                continue;
            activeThumbJobs++;
            thumbJobSeq++;
            Proc.runCommand("wallpaperSpan.vthumb." + thumbJobSeq, ["bash", SpanController.scriptPath, "video-thumb", vp, SpanController.cacheDir], (output, exitCode) => {
                activeThumbJobs = Math.max(0, activeThumbJobs - 1);
                const outPath = exitCode === 0 ? output.trim().split("\n")[0] : "";
                if (outPath) {
                    const updated = Object.assign({}, root.thumbMap);
                    updated[vp] = outPath;
                    root.thumbMap = updated;
                    for (let k = 0; k < filteredModel.count; k++) {
                        if (filteredModel.get(k).path === vp) {
                            filteredModel.setProperty(k, "thumbPath", outPath);
                            break;
                        }
                    }
                }
                root.drainThumbQueue();
            });
        }
    }

    function applyCardDefault(item) {
        if (selectedTarget === "all") {
            SpanController.applyAuto(item.path, item.imgWidth, item.imgHeight, effectivePluginData);
        } else {
            SpanController.applyToMonitor(selectedTarget, item.path);
        }
    }

    function offsetFor(screenName) {
        return Number(localOffsets?.[screenName]) || 0;
    }

    function formatOffset(px) {
        if (!px)
            return "0 px";
        return px < 0 ? (Math.abs(px) + " px ↓") : (px + " px ↑");
    }

    function hasAnyOffset() {
        if (localBezelGapMm !== 0)
            return true;
        for (let i = 0; i < monitors.length; i++) {
            if (offsetFor(monitors[i].name) !== 0)
                return true;
        }
        return false;
    }

    function nudgeOffset(screenName, delta) {
        const next = Object.assign({}, localOffsets);
        const cur = Number(next[screenName]) || 0;
        const clamped = Math.max(-300, Math.min(300, cur + delta));
        if (clamped === 0)
            delete next[screenName];
        else
            next[screenName] = clamped;
        localOffsets = next;
        saveSetting("monitorOffsets", next);
        alignReapplyTimer.restart();
    }

    function nudgeBezelGap(delta) {
        const clamped = Math.max(0, Math.min(40, localBezelGapMm + delta));
        localBezelGapMm = clamped;
        saveSetting("bezelGapMm", clamped);
        alignReapplyTimer.restart();
    }

    function resetAllOffsets() {
        localOffsets = ({});
        localBezelGapMm = 0;
        saveSetting("monitorOffsets", ({}));
        saveSetting("bezelGapMm", 0);
        alignReapplyTimer.restart();
    }

    function syncOffsetsFromPluginData() {
        const saved = pluginData?.monitorOffsets;
        localOffsets = (saved && typeof saved === "object") ? Object.assign({}, saved) : ({});
        const gap = Number(pluginData?.bezelGapMm);
        localBezelGapMm = (!isNaN(gap) && gap >= 0) ? Math.round(gap) : 0;
        refreshMonitors();
    }

    Timer {
        id: alignReapplyTimer
        interval: 220
        repeat: false
        onTriggered: {
            if (root.spannedVideoSource)
                return;
            const src = SpanController.lastSpannedSource || root.pluginData?.lastSpannedSource || "";
            if (src && root.monitors.length > 1 && SessionData.perMonitorWallpaper && !SpanEngine.isVideoPath(src)) {
                SpanController.applySpan(src, 0, 0, root.effectivePluginData);
            }
        }
    }

    function previewUrlFor(path) {
        if (!path || path.startsWith("#"))
            return "";
        return "file://" + path.split("/").map(s => encodeURIComponent(s)).join("/");
    }

    function baseNameOf(path) {
        if (!path)
            return "";
        const s = path.lastIndexOf("/");
        return s >= 0 ? path.slice(s + 1) : path;
    }

    function activeTargetVideo() {
        if (selectedTarget === "all") {
            if (spannedVideoSource)
                return spannedVideoSource;
            for (let i = 0; i < monitors.length; i++) {
                const vp = monitorVideos?.[monitors[i].name];
                if (vp)
                    return vp;
            }
            return "";
        }
        return monitorVideos?.[selectedTarget] || "";
    }

    function isActiveSource(path) {
        if (selectedTarget === "all") {
            if (spannedVideoSource && spannedVideoSource === path)
                return true;
            if (monitors.length > 0 && monitors.every(m => monitorVideos?.[m.name] === path))
                return true;
            if (Object.keys(monitorVideos || {}).length > 0)
                return false;
            if (SpanController.lastSpannedSource && SpanController.lastSpannedSource === path)
                return true;
            return !SessionData.perMonitorWallpaper && SessionData.wallpaperPath === path;
        }
        const liveTarget = monitorVideos?.[selectedTarget];
        if (liveTarget)
            return liveTarget === path;
        if (SpanController.lastSpannedSource && SpanController.lastSpannedSource === path)
            return true;
        return SessionData.perMonitorWallpaper && SessionData.getMonitorWallpaper(selectedTarget) === path;
    }

    onResolvedDirChanged: scanFolder()
    onRecursiveScanChanged: scanFolder()
    onWideThresholdChanged: {
        recountTypes();
        rebuildFiltered();
    }
    onPluginDataChanged: syncOffsetsFromPluginData()

    Component.onCompleted: {
        SpanController.bindPluginService(pluginService);
        syncOffsetsFromPluginData();
        refreshMonitors();
        scanFolder();
    }

    Connections {
        target: SpanController
        function onApplied(mode, sourcePath) {
            if (mode === "span")
                root.saveSetting("lastSpannedSource", sourcePath);
            else if (mode === "same")
                root.saveSetting("lastSpannedSource", "");
        }
        function onCapsCheckedChanged() {
            if (SpanController.hasFfmpeg)
                root.drainThumbQueue();
        }
    }

    Connections {
        target: Quickshell
        function onScreensChanged() {
            root.refreshMonitors();
        }
    }

    Loader {
        id: folderPickerLoader
        active: false
        sourceComponent: FileBrowserModal {
            browserTitle: "Select Wallpaper Folder"
            folderMode: true
            startPath: root.resolvedDir
            onAccepted: paths => {
                if (paths && paths.length > 0) {
                    const clean = Paths.strip(paths[0]).replace(/^file:\/\//, "");
                    root.saveSetting("wallpaperDir", Paths.shortenHome(clean));
                }
            }
            onDialogClosed: folderPickerLoader.active = false
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.spacingM
        spacing: Theme.spacingS

        StyledRect {
            id: monitorStage
            Layout.fillWidth: true
            Layout.preferredHeight: stageColumn.implicitHeight + Theme.spacingS * 2
            radius: Theme.cornerRadius
            color: Theme.cardSurface
            border.width: Theme.outlineWidth
            border.color: Theme.outlineVariant

            ColumnLayout {
                id: stageColumn
                anchors.fill: parent
                anchors.margins: Theme.spacingS
                spacing: Theme.spacingS

                Item {
                    id: stageCanvas
                    Layout.fillWidth: true
                    Layout.preferredHeight: Theme.listItemHeight * 2 + Theme.spacingL
                    clip: true

                    readonly property bool usePhysical: SpanController.fitModeFromData(root.effectivePluginData) === "physical"
                    readonly property var bounds: {
                        const mons = root.monitors;
                        if (!mons || mons.length === 0)
                            return { minX: 0, minY: 0, totalW: 1920, totalH: 1080 };
                        let minX = mons[0].x, minY = mons[0].y;
                        let maxX = mons[0].x + (usePhysical ? (mons[0].physW || mons[0].width) : mons[0].width);
                        let maxY = mons[0].y + (usePhysical ? (mons[0].physH || mons[0].height) : mons[0].height);
                        if (usePhysical) {
                            let curX = 0;
                            for (let i = 0; i < mons.length; i++) {
                                curX += (mons[i].physW || 530);
                                maxY = Math.max(maxY, mons[i].physH || 300);
                            }
                            return { minX: 0, minY: 0, totalW: Math.max(1, curX), totalH: Math.max(1, maxY) };
                        }
                        for (let i = 1; i < mons.length; i++) {
                            if (mons[i].x < minX) minX = mons[i].x;
                            if (mons[i].y < minY) minY = mons[i].y;
                            if (mons[i].x + mons[i].width > maxX) maxX = mons[i].x + mons[i].width;
                            if (mons[i].y + mons[i].height > maxY) maxY = mons[i].y + mons[i].height;
                        }
                        return {
                            minX: minX,
                            minY: minY,
                            totalW: Math.max(1, maxX - minX),
                            totalH: Math.max(1, maxY - minY)
                        };
                    }

                    readonly property real gapPx: 4 + Math.round(root.localBezelGapMm * 0.45)
                    readonly property real availW: Math.max(100, width - Math.max(0, root.monitors.length - 1) * gapPx - 8)
                    readonly property real availH: Math.max(60, height - 16)
                    readonly property real fitScale: Math.min(availW / bounds.totalW, availH / bounds.totalH)
                    readonly property real groupW: bounds.totalW * fitScale + Math.max(0, root.monitors.length - 1) * gapPx
                    readonly property real groupH: bounds.totalH * fitScale
                    readonly property real originX: Math.max(0, (width - groupW) / 2)
                    readonly property real originY: Math.max(0, (height - groupH) / 2)

                    function monitorXOffset(idx) {
                        if (!usePhysical)
                            return (root.monitors[idx].x - bounds.minX) * fitScale;
                        let acc = 0;
                        for (let k = 0; k < idx; k++)
                            acc += (root.monitors[k].physW || 530) * fitScale;
                        return acc;
                    }

                    Repeater {
                        model: root.monitors

                        StyledRect {
                            id: monScreen
                            required property var modelData
                            required property int index

                            readonly property bool isTargeted: root.selectedTarget === modelData.name
                            readonly property bool isActiveInStage: root.selectedTarget === "all" || isTargeted
                            readonly property int offVal: {
                                root.localOffsets;
                                return root.offsetFor(modelData.name);
                            }
                            readonly property string liveVideo: root.monitorVideos?.[modelData.name] || ""
                            readonly property string currentWp: {
                                SessionData.wallpaperPath;
                                SessionData.monitorWallpapers;
                                SessionData.perMonitorWallpaper;
                                return SessionData.getMonitorWallpaper(modelData.name) || "";
                            }
                            readonly property string stagePreviewPath: currentWp || (liveVideo ? (root.thumbMap?.[liveVideo] || "") : "")

                            Component.onCompleted: {
                                if (liveVideo && !stagePreviewPath)
                                    root.requestVideoThumb(liveVideo);
                            }
                            onLiveVideoChanged: {
                                if (liveVideo && !stagePreviewPath)
                                    root.requestVideoThumb(liveVideo);
                            }

                            x: stageCanvas.originX + stageCanvas.monitorXOffset(index) + index * stageCanvas.gapPx
                            y: stageCanvas.originY + (stageCanvas.usePhysical ? 0 : (modelData.y - stageCanvas.bounds.minY) * stageCanvas.fitScale)
                            width: Math.max(80, (stageCanvas.usePhysical ? (modelData.physW || modelData.width) : modelData.width) * stageCanvas.fitScale)
                            height: Math.max(50, (stageCanvas.usePhysical ? (modelData.physH || modelData.height) : modelData.height) * stageCanvas.fitScale)
                            radius: Theme.cornerRadiusS
                            color: Theme.chipSurface
                            border.width: isTargeted ? Theme.outlineWidthFocused : Theme.outlineWidth
                            border.color: isActiveInStage ? Theme.primary : Theme.outlineVariant
                            opacity: isActiveInStage ? 1.0 : 0.55
                            clip: true

                            Image {
                                width: parent.width
                                height: parent.height
                                x: 0
                                y: Math.max(-height * 0.45, Math.min(height * 0.45, -monScreen.offVal * Math.max(stageCanvas.fitScale, 0.25)))
                                source: root.previewUrlFor(monScreen.stagePreviewPath)
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                cache: false
                                sourceSize.width: 360
                                visible: status === Image.Ready
                            }

                            DIcon {
                                anchors.centerIn: parent
                                name: monScreen.liveVideo ? "movie" : "image"
                                size: Theme.iconSize
                                color: Theme.onSurfaceVariant
                                visible: !monScreen.stagePreviewPath
                            }

                            StyledRect {
                                anchors.top: parent.top
                                anchors.right: parent.right
                                anchors.margins: Theme.spacingXS
                                width: offBadgeText.implicitWidth + Theme.spacingS
                                height: offBadgeText.implicitHeight + Theme.spacingXS
                                radius: Theme.cornerRadiusFull
                                color: Theme.primary
                                visible: monScreen.offVal !== 0

                                StyledText {
                                    id: offBadgeText
                                    anchors.centerIn: parent
                                    text: root.formatOffset(monScreen.offVal)
                                    font.pixelSize: Theme.fontSizeXSmall
                                    font.weight: Font.Bold
                                    color: Theme.onPrimary
                                }
                            }

                            Row {
                                anchors.top: parent.top
                                anchors.left: parent.left
                                anchors.margins: Theme.spacingXS
                                spacing: Theme.spacingXS

                                StyledRect {
                                    width: targetTag.implicitWidth + Theme.spacingS
                                    height: targetTag.implicitHeight + Theme.spacingXS
                                    radius: Theme.cornerRadiusFull
                                    color: Theme.primary
                                    visible: monScreen.isTargeted

                                    StyledText {
                                        id: targetTag
                                        anchors.centerIn: parent
                                        text: "TARGET"
                                        font.pixelSize: Theme.fontSizeXSmall
                                        font.weight: Font.Bold
                                        color: Theme.onPrimary
                                    }
                                }

                                StyledRect {
                                    readonly property bool colPaused: {
                                        NiriService.allWorkspaces;
                                        NiriService.windows;
                                        return monScreen.liveVideo !== "" && !root.videoPaused && root.isNiriColumnPaused(monScreen.modelData.name);
                                    }
                                    width: stageLiveTag.implicitWidth + Theme.spacingS
                                    height: stageLiveTag.implicitHeight + Theme.spacingXS
                                    radius: Theme.cornerRadiusFull
                                    color: (root.videoPaused || colPaused) ? Theme.secondaryContainer : Theme.primary
                                    visible: monScreen.liveVideo !== ""

                                    StyledText {
                                        id: stageLiveTag
                                        anchors.centerIn: parent
                                        text: root.videoPaused ? "PAUSED" : (parent.colPaused ? "PAUSED · COL" : "LIVE")
                                        font.pixelSize: Theme.fontSizeXSmall
                                        font.weight: Font.Bold
                                        color: (root.videoPaused || parent.colPaused) ? Theme.onSecondaryContainer : Theme.onPrimary
                                    }
                                }
                            }

                            Rectangle {
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.bottom: parent.bottom
                                height: stageMonLabel.implicitHeight + Theme.spacingS
                                color: Theme.withAlpha(Theme.surface, 0.8)

                                StyledText {
                                    id: stageMonLabel
                                    anchors.fill: parent
                                    anchors.leftMargin: Theme.spacingXS
                                    anchors.rightMargin: Theme.spacingXS
                                    verticalAlignment: Text.AlignVCenter
                                    horizontalAlignment: Text.AlignHCenter
                                    text: (monScreen.index + 1) + ". " + monScreen.modelData.name + " · " + monScreen.modelData.width + "×" + monScreen.modelData.height + (monScreen.modelData.diagInches ? (" (" + monScreen.modelData.diagInches + "\")") : "")
                                    font.pixelSize: Theme.fontSizeXSmall
                                    font.weight: Font.Medium
                                    color: Theme.surfaceText
                                    elide: Text.ElideRight
                                }
                            }

                            StateLayer {
                                anchors.fill: parent
                                tooltipText: "Click to target " + monScreen.modelData.name
                                onClicked: root.selectedTarget = monScreen.modelData.name
                            }
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacingS

                    DButton {
                        text: root.monitors.length > 1 ? ("All (" + root.monitors.length + ")") : "All"
                        iconName: "desktop_windows"
                        buttonHeight: Theme.buttonHeightXXS
                        minimumWidth: 78
                        variant: root.selectedTarget === "all" ? "filled" : "tonal"
                        tooltipText: "Select all displays (Span / Same)"
                        onClicked: root.selectedTarget = "all"
                    }

                    Row {
                        spacing: Theme.spacingXS
                        visible: root.selectedTarget === "all"

                        DToggle {
                            anchors.verticalCenter: parent.verticalCenter
                            hideText: true
                            checked: root.autoSplitWide
                            onToggled: checked => root.saveSetting("autoSplitWide", checked)
                        }

                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Auto-split wide"
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.onSurface
                        }
                    }

                    StyledText {
                        Layout.fillWidth: true
                        text: root.selectedTarget === "all" ? "" : ("Target: " + root.selectedTarget)
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.onSurfaceVariant
                        elide: Text.ElideRight
                    }

                    DButton {
                        visible: root.monitors.length > 1
                        text: "Align"
                        iconName: "vertical_align_center"
                        buttonHeight: Theme.buttonHeightXXS
                        minimumWidth: 74
                        variant: (root.showAlignBar || root.hasAnyOffset()) ? "filled" : "tonal"
                        tooltipText: "Vertical alignment per display"
                        onClicked: root.showAlignBar = !root.showAlignBar
                    }
                }
            }
        }

        StyledRect {
            Layout.fillWidth: true
            Layout.preferredHeight: alignFlow.implicitHeight + Theme.spacingXS * 2
            visible: root.showAlignBar && root.monitors.length > 1
            radius: Theme.cornerRadius
            color: Theme.cardSurface
            border.width: Theme.outlineWidth
            border.color: Theme.outlineVariant

            Flow {
                id: alignFlow
                anchors.fill: parent
                anchors.margins: Theme.spacingXS
                spacing: Theme.spacingS

                Repeater {
                    model: root.monitors

                    StyledRect {
                        id: alignChip
                        required property var modelData
                        required property int index

                        readonly property int offVal: root.offsetFor(modelData.name)

                        width: alignChipRow.implicitWidth + Theme.spacingS * 2
                        height: alignChipRow.implicitHeight + Theme.spacingXS * 2
                        radius: Theme.cornerRadiusS
                        color: Theme.chipSurface
                        border.width: Theme.outlineWidth
                        border.color: offVal !== 0 ? Theme.primary : Theme.outlineVariant

                        Row {
                            id: alignChipRow
                            anchors.centerIn: parent
                            spacing: Theme.spacingXS

                            StyledText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: alignChip.modelData.name
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: Font.DemiBold
                                color: Theme.onSurface
                            }

                            StyledText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: root.formatOffset(alignChip.offVal)
                                font.pixelSize: Theme.fontSizeSmall
                                color: alignChip.offVal !== 0 ? Theme.primary : Theme.onSurfaceVariant
                                width: 46
                                horizontalAlignment: Text.AlignHCenter
                            }

                            DButton {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "↓10"
                                buttonHeight: Theme.buttonHeightXXS
                                minimumWidth: 34
                                variant: "tonal"
                                tooltipText: "Move wallpaper down 10 px"
                                onClicked: root.nudgeOffset(alignChip.modelData.name, -10)
                            }

                            DButton {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "↓2"
                                buttonHeight: Theme.buttonHeightXXS
                                minimumWidth: 30
                                variant: "tonal"
                                tooltipText: "Move wallpaper down 2 px"
                                onClicked: root.nudgeOffset(alignChip.modelData.name, -2)
                            }

                            DButton {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "↑2"
                                buttonHeight: Theme.buttonHeightXXS
                                minimumWidth: 30
                                variant: "tonal"
                                tooltipText: "Move wallpaper up 2 px"
                                onClicked: root.nudgeOffset(alignChip.modelData.name, 2)
                            }

                            DButton {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "↑10"
                                buttonHeight: Theme.buttonHeightXXS
                                minimumWidth: 34
                                variant: "tonal"
                                tooltipText: "Move wallpaper up 10 px"
                                onClicked: root.nudgeOffset(alignChip.modelData.name, 10)
                            }
                        }
                    }
                }

                StyledRect {
                    width: bezelRow.implicitWidth + Theme.spacingS * 2
                    height: bezelRow.implicitHeight + Theme.spacingXS * 2
                    radius: Theme.cornerRadiusS
                    color: Theme.chipSurface
                    border.width: Theme.outlineWidth
                    border.color: root.localBezelGapMm > 0 ? Theme.primary : Theme.outlineVariant

                    Row {
                        id: bezelRow
                        anchors.centerIn: parent
                        spacing: Theme.spacingXS

                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Gap"
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: Font.DemiBold
                            color: Theme.onSurface
                        }

                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.localBezelGapMm + " mm"
                            font.pixelSize: Theme.fontSizeSmall
                            color: root.localBezelGapMm > 0 ? Theme.primary : Theme.onSurfaceVariant
                            width: 40
                            horizontalAlignment: Text.AlignHCenter
                        }

                        DButton {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "-2"
                            buttonHeight: Theme.buttonHeightXXS
                            minimumWidth: 28
                            variant: "tonal"
                            tooltipText: "Decrease physical bezel gap 2 mm"
                            onClicked: root.nudgeBezelGap(-2)
                        }

                        DButton {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "+2"
                            buttonHeight: Theme.buttonHeightXXS
                            minimumWidth: 28
                            variant: "tonal"
                            tooltipText: "Increase physical bezel gap 2 mm"
                            onClicked: root.nudgeBezelGap(2)
                        }
                    }
                }

                DButton {
                    visible: root.hasAnyOffset()
                    text: "Reset"
                    buttonHeight: Theme.buttonHeightXS
                    minimumWidth: Theme.buttonMinWidth
                    variant: "tonal"
                    onClicked: root.resetAllOffsets()
                }
            }
        }

        StyledRect {
            id: liveBar
            Layout.fillWidth: true
            Layout.preferredHeight: Theme.buttonHeightS
            visible: root.activeLivePath !== ""
            radius: Theme.cornerRadius
            color: Theme.cardSurface
            border.width: Theme.outlineWidth
            border.color: Theme.outlineVariant

            readonly property var liveSettings: SpanController.effectiveVideoSettings(root.pluginData, root.activeLivePath)

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Theme.spacingS
                anchors.rightMargin: Theme.spacingS
                spacing: Theme.spacingXS

                DIcon {
                    name: "movie"
                    size: Theme.iconSizeSmall
                    color: Theme.primary
                }

                StyledText {
                    Layout.fillWidth: true
                    text: {
                        NiriService.allWorkspaces;
                        NiriService.windows;
                        const suffix = root.videoPaused ? " (Paused)" : (root.anyTargetNiriPaused() ? " (Paused · column active)" : "");
                        return root.baseNameOf(root.activeLivePath) + suffix;
                    }
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Medium
                    color: Theme.onSurface
                    elide: Text.ElideMiddle
                }

                DActionButton {
                    iconName: root.videoPaused ? "play_arrow" : "pause"
                    buttonSize: Theme.buttonHeightXXS
                    tooltipText: root.videoPaused ? "Resume live wallpaper" : "Pause live wallpaper"
                    onClicked: SpanController.setVideosPaused(!root.videoPaused)
                }

                DActionButton {
                    iconName: "stop"
                    buttonSize: Theme.buttonHeightXXS
                    tooltipText: root.selectedTarget === "all" ? "Stop live wallpaper on all displays" : ("Stop live wallpaper on " + root.selectedTarget)
                    onClicked: SpanController.stopVideos(root.selectedTarget === "all" ? null : [root.selectedTarget])
                }

                DButton {
                    text: liveBar.liveSettings.panscan >= 0.9 ? "Fill" : (liveBar.liveSettings.panscan <= 0.1 ? "Fit" : "50%")
                    buttonHeight: Theme.buttonHeightXXS
                    minimumWidth: 44
                    variant: "tonal"
                    tooltipText: "Cycle video fill mode (Fill / Balance / Fit)"
                    onClicked: {
                        const cur = liveBar.liveSettings.panscan;
                        const next = cur >= 0.9 ? 0.0 : (cur <= 0.1 ? 0.5 : 1.0);
                        SpanController.updateVideoSetting(root.activeLivePath, "panscan", next, root.pluginData);
                    }
                }

                DActionButton {
                    iconName: liveBar.liveSettings.volume > 0 ? "volume_up" : "volume_off"
                    buttonSize: Theme.buttonHeightXXS
                    tooltipText: liveBar.liveSettings.volume > 0 ? "Mute video" : "Unmute video (25%)"
                    onClicked: {
                        const nextVol = liveBar.liveSettings.volume > 0 ? 0 : 25;
                        SpanController.updateVideoSetting(root.activeLivePath, "volume", nextVol, root.pluginData);
                    }
                }

                DSlider {
                    id: liveVolSlider
                    Layout.preferredWidth: 96
                    minimum: 0
                    maximum: 100
                    unit: "%"
                    wheelEnabled: false
                    value: Math.round(liveBar.liveSettings.volume || 0)
                    onSliderDragFinished: function(finalValue) {
                        SpanController.updateVideoSetting(root.activeLivePath, "volume", Math.round(finalValue), root.pluginData);
                    }
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacingS

            StyledRect {
                Layout.preferredWidth: 170
                Layout.preferredHeight: Theme.buttonHeightXS
                radius: Theme.cornerRadius
                color: Theme.chipSurface
                border.width: Theme.outlineWidth
                border.color: Theme.outlineVariant

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Theme.spacingS
                    anchors.rightMargin: Theme.spacingS
                    spacing: Theme.spacingXS

                    DIcon {
                        name: "folder_open"
                        size: Theme.iconSizeSmall
                        color: Theme.primary
                    }

                    StyledText {
                        Layout.fillWidth: true
                        text: Paths.shortenHome(root.resolvedDir)
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.onSurface
                        elide: Text.ElideMiddle
                    }
                }

                StateLayer {
                    anchors.fill: parent
                    tooltipText: root.resolvedDir
                    onClicked: {
                        folderPickerLoader.active = true;
                        if (folderPickerLoader.item)
                            folderPickerLoader.item.open();
                    }
                }
            }

            DActionButton {
                iconName: "refresh"
                buttonSize: Theme.buttonHeightXS
                tooltipText: "Rescan folder"
                onClicked: root.scanFolder()
            }

            DSearchField {
                id: searchField
                Layout.fillWidth: true
                fieldHeight: Theme.buttonHeightXS
                placeholderText: "Search..."
                onTextChanged: {
                    root.searchQuery = text;
                    root.rebuildFiltered();
                }
            }

            StyledRect {
                Layout.preferredWidth: filterRow.implicitWidth + Theme.spacingXS * 2
                Layout.preferredHeight: Theme.buttonHeightXS
                radius: Theme.cornerRadius
                color: Theme.chipSurface
                border.width: Theme.outlineWidth
                border.color: Theme.outlineVariant

                Row {
                    id: filterRow
                    anchors.centerIn: parent
                    spacing: Theme.spacingXXS

                    Repeater {
                        model: [
                            { id: "all", label: "All (" + (root.wideCount + root.normalCount) + ")" },
                            { id: "wide", label: "Wide (" + root.wideCount + ")" },
                            { id: "normal", label: "Normal (" + root.normalCount + ")" },
                            { id: "live", label: "Live (" + root.liveCount + ")" }
                        ]

                        StyledRect {
                            required property var modelData
                            readonly property bool active: root.filterMode === modelData.id

                            width: chipLabel.implicitWidth + Theme.spacingM
                            height: Theme.buttonHeightXXS
                            radius: Theme.cornerRadiusS
                            color: active ? Theme.secondaryContainer : "transparent"

                            StyledText {
                                id: chipLabel
                                anchors.centerIn: parent
                                text: modelData.label
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: active ? Font.DemiBold : Font.Normal
                                color: active ? Theme.onSecondaryContainer : Theme.onSurfaceVariant
                            }

                            StateLayer {
                                anchors.fill: parent
                                onClicked: {
                                    root.filterMode = modelData.id;
                                    root.rebuildFiltered();
                                }
                            }
                        }
                    }
                }
            }
        }

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            DGridView {
                id: gridView
                anchors.fill: parent
                readonly property int cols: Math.max(2, Math.floor(width / 210))
                readonly property bool showCardActions: root.selectedTarget === "all" && root.monitors.length > 1
                cellWidth: width / cols
                cellHeight: cellWidth * 0.62
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                model: filteredModel
                visible: filteredModel.count > 0

                delegate: Item {
                    id: cellRoot
                    required property string mediaType
                    required property string path
                    required property string name
                    required property int imgWidth
                    required property int imgHeight
                    required property string aspect
                    required property bool isWide
                    required property string thumbPath

                    readonly property bool isVideo: mediaType === "video"

                    width: gridView.cellWidth
                    height: gridView.cellHeight

                    Component.onCompleted: {
                        if (isVideo && !thumbPath)
                            root.requestVideoThumb(path);
                    }

                    readonly property bool isCurrent: {
                        SessionData.wallpaperPath;
                        SessionData.monitorWallpapers;
                        SpanController.lastSpannedSource;
                        root.monitorVideos;
                        root.spannedVideoSource;
                        return root.isActiveSource(path);
                    }

                    StyledRect {
                        id: cardRect
                        anchors.fill: parent
                        anchors.margins: Theme.spacingXS
                        radius: Theme.cornerRadius
                        color: Theme.cardSurface
                        border.width: cellRoot.isCurrent ? Theme.outlineWidthFocused : Theme.outlineWidth
                        border.color: cellRoot.isCurrent ? Theme.primary : Theme.outlineVariant
                        clip: true

                        HoverHandler {
                            id: cardHover
                        }

                        Image {
                            id: cardPreview
                            anchors.fill: parent
                            source: cellRoot.isVideo
                                ? (cellRoot.thumbPath ? root.previewUrlFor(cellRoot.thumbPath) : "")
                                : root.previewUrlFor(cellRoot.path)
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            cache: false
                            sourceSize.width: 380
                        }

                        DIcon {
                            anchors.centerIn: parent
                            name: "movie"
                            size: Theme.iconSizeLarge
                            color: Theme.onSurfaceVariant
                            visible: cellRoot.isVideo && cardPreview.status !== Image.Ready
                        }

                        StateLayer {
                            anchors.fill: parent
                            tooltipText: cellRoot.name + (cellRoot.imgWidth > 0 ? (" (" + cellRoot.imgWidth + "×" + cellRoot.imgHeight + ")") : "")
                            onClicked: root.applyCardDefault(cellRoot)
                        }

                        StyledRect {
                            anchors.top: parent.top
                            anchors.left: parent.left
                            anchors.margins: Theme.spacingXS
                            width: badgeText.implicitWidth + Theme.spacingS
                            height: badgeText.implicitHeight + Theme.spacingXS
                            radius: Theme.cornerRadiusS
                            color: Theme.primary
                            visible: cellRoot.isWide || cellRoot.isVideo

                            StyledText {
                                id: badgeText
                                anchors.centerIn: parent
                                text: cellRoot.isVideo
                                    ? (cellRoot.isWide && cellRoot.aspect ? ("LIVE · " + cellRoot.aspect) : "LIVE")
                                    : ("WIDE · " + cellRoot.aspect)
                                font.pixelSize: Theme.fontSizeXSmall
                                font.weight: Font.Bold
                                color: Theme.onPrimary
                            }
                        }

                        StyledRect {
                            anchors.top: parent.top
                            anchors.right: parent.right
                            anchors.margins: Theme.spacingXS
                            width: Theme.iconSizeMedium
                            height: Theme.iconSizeMedium
                            radius: Theme.cornerRadiusFull
                            color: Theme.primary
                            visible: cellRoot.isCurrent

                            DIcon {
                                anchors.centerIn: parent
                                name: "check"
                                size: Theme.iconSizeSmall
                                color: Theme.onPrimary
                            }
                        }

                        Rectangle {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            height: hoverCol.implicitHeight + Theme.spacingXS * 2
                            color: Theme.withAlpha(Theme.surface, 0.85)
                            visible: cardHover.hovered

                            ColumnLayout {
                                id: hoverCol
                                anchors.fill: parent
                                anchors.margins: Theme.spacingXS
                                spacing: Theme.spacingXS

                                StyledText {
                                    Layout.fillWidth: true
                                    text: cellRoot.name
                                    font.pixelSize: Theme.fontSizeXSmall
                                    font.weight: Font.Medium
                                    color: Theme.surfaceText
                                    elide: Text.ElideMiddle
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Theme.spacingXS
                                    visible: gridView.showCardActions

                                    DButton {
                                        Layout.fillWidth: true
                                        text: "Span"
                                        buttonHeight: Theme.buttonHeightXXS
                                        minimumWidth: 42
                                        variant: cellRoot.isWide ? "filled" : "tonal"
                                        onClicked: SpanController.applySpan(cellRoot.path, cellRoot.imgWidth, cellRoot.imgHeight, root.effectivePluginData)
                                    }

                                    DButton {
                                        Layout.fillWidth: true
                                        text: "Same"
                                        buttonHeight: Theme.buttonHeightXXS
                                        minimumWidth: 42
                                        variant: "tonal"
                                        onClicked: SpanController.applySameOnAll(cellRoot.path)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Column {
                anchors.centerIn: parent
                spacing: Theme.spacingS
                visible: filteredModel.count === 0
                width: Math.min(parent.width - Theme.spacingL * 2, 380)

                DIcon {
                    anchors.horizontalCenter: parent.horizontalCenter
                    name: root.scanning ? "hourglass_top" : "wallpaper"
                    size: Theme.iconSizeLarge
                    color: Theme.onSurfaceVariant
                }

                StyledText {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: root.scanning ? "Scanning wallpaper folder..." : (root.allItems.length === 0 ? "No wallpapers found in " + Paths.shortenHome(root.resolvedDir) : "No wallpapers match the current filter")
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.onSurfaceVariant
                    wrapMode: Text.WordWrap
                }
            }

            StyledRect {
                anchors.bottom: parent.bottom
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottomMargin: Theme.spacingS
                width: busyRow.implicitWidth + Theme.spacingM * 2
                height: Theme.buttonHeightXS
                radius: Theme.cornerRadiusFull
                color: Theme.primary
                visible: SpanController.busy

                Row {
                    id: busyRow
                    anchors.centerIn: parent
                    spacing: Theme.spacingXS

                    DIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "crop"
                        size: Theme.iconSizeSmall
                        color: Theme.onPrimary
                    }

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Splitting wide wallpaper..."
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.onPrimary
                    }
                }
            }
        }
    }
}
