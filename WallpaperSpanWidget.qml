import QtQuick
import Quickshell
import qs.Common
import qs.DCommon.Widgets
import qs.Modules.Plugins
import qs.Services
import qs.Widgets

PluginComponent {
    id: root

    layerNamespacePlugin: "wallpaper-span"
    property var popoutService: null

    ccWidgetIcon: "panorama"
    ccWidgetPrimaryText: "Wallpaper Span"
    ccWidgetSecondaryText: {
        const mv = pluginData?.monitorVideos || ({});
        if (Object.keys(mv).length > 0)
            return pluginData?.videoPaused ? "Live (Paused)" : "Live Wallpaper";
        return SessionData.perMonitorWallpaper ? "Per-display / Spanned" : "Same on all";
    }
    ccWidgetIsToggle: false
    onCcWidgetToggled: slideout.toggle()

    pillClickAction: () => {
        slideout.toggle();
    }

    DSlideout {
        id: slideout
        modelData: root.parentScreen || Screen
        title: "Wallpaper Span"
        slideoutWidth: 780
        expandable: true
        expandedWidthValue: 1120

        content: Component {
            WallpaperSpanContent {
                pluginService: root.pluginService
                pluginData: root.pluginData
                pluginId: root.pluginId || "wallpaperSpan"
                slideoutRef: slideout
            }
        }
    }

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            DIcon {
                name: "panorama"
                color: Theme.primary
                size: root.iconSize
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXS

            DIcon {
                name: "panorama"
                color: Theme.primary
                size: root.iconSize
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }
}
