import QtQuick
import qs.Common
import qs.DCommon.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: "wallpaperSpan"

    Component.onCompleted: {
        SpanController.bindPluginService(pluginService);
        SpanController.refreshCapabilities();
    }

    StyledText {
        width: parent.width
        text: "Wallpaper Span"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.onSurface
    }

    StyledText {
        width: parent.width
        text: "Automatically split wide images and videos across monitors, or set normal wallpapers uniformly or per display."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.onSurfaceVariant
        wrapMode: Text.WordWrap
    }

    StringSetting {
        settingKey: "wallpaperDir"
        label: "Wallpaper Folder"
        description: "Directory scanned for image and video wallpapers"
        placeholder: "~/Pictures/Wallpapers"
        defaultValue: "~/Pictures/Wallpapers"
    }

    ToggleSetting {
        settingKey: "recursive"
        label: "Scan Subfolders"
        description: "Include wallpapers inside nested subdirectories"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "autoSplitWide"
        label: "Auto-Split Wide Wallpapers"
        description: "In All Displays mode, automatically split images and videos meeting the aspect threshold across monitors"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "autoSplitExternal"
        label: "Auto-Split External Wallpaper Changes"
        description: "Also split wide images when set outside this plugin (for example via DMS Dash or Settings)"
        defaultValue: false
    }

    SliderSetting {
        settingKey: "wideThresholdPercent"
        label: "Wide Aspect Threshold"
        description: "Minimum width-to-height ratio (in percent) treated as wide. 220% = 2.2:1 (covers 21:9, 32:9, 3840x1080)"
        defaultValue: 220
        minimum: 180
        maximum: 320
        unit: "%"
    }

    SelectionSetting {
        settingKey: "spanFitMode"
        label: "Span Crop Strategy"
        description: "Physical Space matches real screen sizes, PPIs, bezel gaps, and vertical offsets (Spanright method)"
        options: [
            {
                "label": "Physical Space (Spanright)",
                "value": "physical"
            },
            {
                "label": "Logical Pixel Cover",
                "value": "cover"
            },
            {
                "label": "Equal Horizontal Slices",
                "value": "equal"
            }
        ]
        defaultValue: "physical"
    }

    SliderSetting {
        settingKey: "bezelGapMm"
        label: "Physical Bezel Gap"
        description: "Physical gap between adjacent display panels so lines cross bezels smoothly"
        defaultValue: 0
        minimum: 0
        maximum: 40
        unit: "mm"
    }

    StyledText {
        width: parent.width
        text: "Live Wallpapers (mpvpaper)"
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Bold
        color: Theme.onSurface
        topPadding: Theme.spacingS
    }

    StyledRect {
        width: parent.width
        height: capsCol.implicitHeight + Theme.spacingS * 2
        radius: Theme.cornerRadius
        color: SpanController.capsChecked && !SpanController.hasMpvpaper
            ? Theme.withAlpha(Theme.error, 0.12)
            : Theme.chipSurface
        border.color: SpanController.capsChecked && !SpanController.hasMpvpaper
            ? Theme.error
            : Theme.outlineVariant
        border.width: Theme.outlineWidth

        Column {
            id: capsCol
            anchors.fill: parent
            anchors.margins: Theme.spacingS
            spacing: 2

            StyledText {
                width: parent.width
                text: {
                    if (!SpanController.capsChecked)
                        return "Checking live wallpaper dependencies...";
                    const parts = [
                        "mpvpaper: " + (SpanController.hasMpvpaper ? "ready" : "not installed"),
                        "ffmpeg: " + (SpanController.hasFfmpeg ? "ready" : "missing"),
                        "ffprobe: " + (SpanController.hasFfprobe ? "ready" : "missing")
                    ];
                    return parts.join("  ·  ");
                }
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                color: SpanController.capsChecked && !SpanController.hasMpvpaper ? Theme.error : Theme.onSurface
            }

            StyledText {
                width: parent.width
                visible: SpanController.capsChecked && !SpanController.hasMpvpaper
                text: "Install mpvpaper to enable live video playback: sudo pacman -S mpvpaper"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.onSurfaceVariant
                wrapMode: Text.WordWrap
            }
        }
    }

    SelectionSetting {
        settingKey: "defaultHwdec"
        label: "Hardware Decoding"
        description: "Hardware video decoder passed to mpvpaper (defaults to auto)"
        options: [
            { "label": "Auto", "value": "auto" },
            { "label": "NVDEC (NVIDIA)", "value": "nvdec" },
            { "label": "VA-API (AMD / Intel)", "value": "vaapi" },
            { "label": "VDPAU", "value": "vdpau" },
            { "label": "Software (CPU)", "value": "no" }
        ]
        defaultValue: "auto"
    }

    SelectionSetting {
        settingKey: "defaultPanscan"
        label: "Default Video Scaling"
        description: "How videos fill the display when aspect ratios differ"
        options: [
            { "label": "Fill Screen (Crop)", "value": 1.0 },
            { "label": "Balanced (50%)", "value": 0.5 },
            { "label": "Fit Screen (Letterbox)", "value": 0.0 }
        ]
        defaultValue: 1.0
    }

    SliderSetting {
        settingKey: "defaultVolume"
        label: "Default Video Volume"
        description: "Audio volume for newly started live wallpapers (0 = muted)"
        defaultValue: 0
        minimum: 0
        maximum: 100
        unit: "%"
    }

    SelectionSetting {
        settingKey: "restartInterval"
        label: "Auto-Restart Playback"
        description: "Periodically restart mpvpaper processes to keep memory usage steady"
        options: [
            { "label": "Disabled", "value": 0 },
            { "label": "Every 30 minutes", "value": 30 },
            { "label": "Every 1 hour", "value": 60 },
            { "label": "Every 2 hours", "value": 120 },
            { "label": "Every 4 hours", "value": 240 }
        ]
        defaultValue: 60
    }

    ToggleSetting {
        settingKey: "videoPaletteSync"
        label: "Sync DMS Palette from Video"
        description: "Extract a still frame via ffmpeg so matugen theming matches the active video wallpaper"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "pauseOnNiriColumn"
        label: "Pause on Niri Window Columns"
        description: "Automatically stop mpvpaper on displays whose active Niri workspace contains any window column to minimize RAM and CPU usage"
        defaultValue: true
    }

    StyledRect {
        width: parent.width
        height: cacheRow.implicitHeight + Theme.spacingM * 2
        radius: Theme.cornerRadius
        color: Theme.chipSurface
        border.color: Theme.outlineVariant
        border.width: Theme.outlineWidth

        Row {
            id: cacheRow
            anchors.fill: parent
            anchors.margins: Theme.spacingM
            spacing: Theme.spacingM

            Column {
                width: parent.width - clearButton.width - Theme.spacingM
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2

                StyledText {
                    width: parent.width
                    text: "Span & Thumbnail Cache"
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                    color: Theme.onSurface
                }

                StyledText {
                    width: parent.width
                    text: SpanController.cacheDir
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.onSurfaceVariant
                    elide: Text.ElideMiddle
                }
            }

            DButton {
                id: clearButton
                anchors.verticalCenter: parent.verticalCenter
                text: "Clear Cache"
                iconName: "delete_sweep"
                variant: "tonal"
                onClicked: SpanController.clearCache()
            }
        }
    }

    StyledRect {
        width: parent.width
        height: alignResetRow.implicitHeight + Theme.spacingM * 2
        radius: Theme.cornerRadius
        color: Theme.chipSurface
        border.color: Theme.outlineVariant
        border.width: Theme.outlineWidth

        Row {
            id: alignResetRow
            anchors.fill: parent
            anchors.margins: Theme.spacingM
            spacing: Theme.spacingM

            Column {
                width: parent.width - resetOffsetsButton.width - Theme.spacingM
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2

                StyledText {
                    width: parent.width
                    text: "Display Vertical Alignment Offsets"
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                    color: Theme.onSurface
                }

                StyledText {
                    width: parent.width
                    text: {
                        const offsets = root.loadValue("monitorOffsets", {});
                        const keys = offsets ? Object.keys(offsets).filter(k => Number(offsets[k]) !== 0) : [];
                        if (keys.length === 0)
                            return "No vertical offsets configured (adjust via Align button in Wallpaper Span panel)";
                        return keys.map(k => k + ": " + offsets[k] + " px").join("  ·  ");
                    }
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.onSurfaceVariant
                    elide: Text.ElideMiddle
                }
            }

            DButton {
                id: resetOffsetsButton
                anchors.verticalCenter: parent.verticalCenter
                text: "Reset"
                iconName: "restart_alt"
                variant: "tonal"
                onClicked: {
                    root.saveValue("monitorOffsets", {});
                    root.saveValue("bezelGapMm", 0);
                    ToastService.showInfo("Wallpaper Span", "Reset display offsets and bezel gap");
                }
            }
        }
    }
}
