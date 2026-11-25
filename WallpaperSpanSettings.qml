import QtQuick
import qs.Common
import qs.DCommon.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: "wallpaperSpan"

    StyledText {
        width: parent.width
        text: "Wallpaper Span"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.onSurface
    }

    StyledText {
        width: parent.width
        text: "Automatically split wide wallpapers across your monitors, or apply normal wallpapers uniformly or per-display."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.onSurfaceVariant
        wrapMode: Text.WordWrap
    }

    StringSetting {
        settingKey: "wallpaperDir"
        label: "Wallpaper Folder"
        description: "Directory scanned by the Wallpaper Span browser"
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
        description: "In All Displays mode, automatically split wallpapers meeting the aspect threshold across monitors"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "autoSplitExternal"
        label: "Auto-Split External Wallpaper Changes"
        description: "Also split wide wallpapers when set outside this plugin (for example via DMS Dash or Settings)"
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
                    text: "Split Image Cache"
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
