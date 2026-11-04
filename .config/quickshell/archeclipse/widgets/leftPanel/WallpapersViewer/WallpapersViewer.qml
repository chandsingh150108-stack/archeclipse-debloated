import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.theme
import qs.widgets.shared
import qs.services

// Wallpapers tab: a flat grid over the user's own files only
// (~/.config/wallpapers/custom). Clicking a tile sets it on the focused workspace
// and regenerates the palette from it. No providers, search, tags or paging.
Item {
    id: root

    property string monitorName: ""
    // Files from the custom folder (and any subfolder below it), in scan order.
    readonly property var files: {
        const cats = WallpaperService.wallpapers || {};
        const out = [];
        for (const key of Object.keys(cats)) {
            if (key === "custom" || key.indexOf("custom/") === 0)
                out.push.apply(out, cats[key] || []);
        }
        return out;
    }
    readonly property string customDir: WallpaperService.wallpaperFolder + "/custom"
    // The panel is per-monitor, but a set always targets what is focused right now.
    readonly property string targetMonitor: Hyprland.focusedMonitor?.name || root.monitorName
    readonly property int targetWorkspace: Hyprland.focusedWorkspace?.id ?? 1

    property string applyingPath: ""
    property string statusText: ""
    property string errorText: ""

    Component.onCompleted: WallpaperService.start()

    function fileName(path) {
        return String(path || "").split("/").pop();
    }

    function shortDir(path) {
        const home = Quickshell.env("HOME");
        return String(path).replace(home, "~");
    }

    function setWallpaper(path) {
        if (!path || setProc.running || paletteProc.running)
            return;
        root.applyingPath = String(path);
        root.errorText = "";
        root.statusText = "Setting on workspace " + root.targetWorkspace + "…";
        setProc.command = ["walleclipse", "set", root.targetMonitor, String(root.targetWorkspace), root.applyingPath];
        setProc.running = true;
    }

    Process {
        id: setProc
        onExited: code => {
            if (code !== 0) {
                root.applyingPath = "";
                root.statusText = "";
                root.errorText = "walleclipse set failed (exit " + code + ")";
                return;
            }
            // Same palette behaviour as the wallpaper panel: the colors follow the
            // wallpaper that was just applied.
            root.statusText = "Regenerating palette…";
            paletteProc.command = ["coloreclipse", "wal", root.applyingPath];
            paletteProc.running = true;
        }
    }

    Process {
        id: paletteProc
        onExited: code => {
            if (code !== 0) {
                root.errorText = "Wallpaper set, but coloreclipse wal failed (exit " + code + ")";
                root.statusText = "";
            } else {
                root.statusText = root.fileName(root.applyingPath) + " · workspace " + root.targetWorkspace;
            }
            root.applyingPath = "";
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: Theme.spacing

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacing

            Text {
                Layout.fillWidth: true
                text: "Wallpapers"
                color: Theme.fg
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize + 2
                font.bold: true
                elide: Text.ElideRight
            }
            Text {
                text: root.files.length
                color: Theme.fgDim
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize - 1
            }
            AppButton {
                icon: Icons.refresh
                tooltipText: "Rescan " + root.shortDir(root.customDir)
                onClicked: WallpaperService.refresh()
            }
        }

        Text {
            Layout.fillWidth: true
            visible: root.files.length > 0 && root.statusText !== ""
            text: root.statusText
            color: Theme.fgDim
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 2
            elide: Text.ElideMiddle
        }
        Text {
            Layout.fillWidth: true
            visible: root.errorText !== ""
            text: root.errorText
            color: Theme.danger
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize - 2
            wrapMode: Text.WordWrap
        }

        GridView {
            id: grid
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.files.length > 0
            clip: true
            model: root.files
            cellWidth: Math.max(1, Math.floor(width / 2))
            cellHeight: Math.round(grid.cellWidth * 0.62)
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar {
                policy: ScrollBar.AsNeeded
            }

            delegate: Rectangle {
                id: tile
                property var modelData
                width: grid.cellWidth - Theme.spacing
                height: grid.cellHeight - Theme.spacing
                radius: Theme.radius
                color: Theme.surface
                border.width: ma.containsMouse || root.applyingPath === tile.modelData ? 2 : 0
                border.color: root.applyingPath === tile.modelData ? Theme.accent : Theme.muted
                opacity: root.applyingPath !== "" && root.applyingPath !== tile.modelData ? 0.55 : 1

                readonly property bool isVideo: WallpaperService.isVideoFile(tile.modelData)
                readonly property string thumb: WallpaperService.thumbFor(tile.modelData)
                readonly property string fileName: root.fileName(tile.modelData)

                AppImage {
                    anchors.fill: parent
                    source: tile.isVideo ? (tile.thumb !== "" ? "file://" + tile.thumb : "") : "file://" + tile.modelData
                    fallbackSource: tile.isVideo ? "" : "file://" + tile.modelData
                    sourceWidth: Math.max(1, Math.round(tile.width * 2))
                }

                // Video without a generated first-frame thumb yet.
                Column {
                    anchors.centerIn: parent
                    visible: tile.isVideo && tile.thumb === ""
                    spacing: 4
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: Icons.video
                        color: Theme.fgDim
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fs(2)
                    }
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: Math.max(0, tile.width - 12)
                        text: tile.fileName
                        color: Theme.fgDim
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 3
                        elide: Text.ElideMiddle
                        horizontalAlignment: Text.AlignHCenter
                    }
                }

                // Filename strip: fades in on hover so the grid stays clean.
                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: 22
                    radius: Theme.radius
                    color: Theme.scrim
                    opacity: ma.containsMouse ? 1 : 0
                    Behavior on opacity {
                        NumberAnimation {
                            duration: 120
                        }
                    }
                    Text {
                        anchors.fill: parent
                        anchors.leftMargin: 6
                        anchors.rightMargin: 6
                        verticalAlignment: Text.AlignVCenter
                        text: tile.fileName
                        color: Theme.onMediaInk
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 3
                        elide: Text.ElideMiddle
                    }
                }

                MouseArea {
                    id: ma
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.setWallpaper(tile.modelData)
                }
            }
        }

        // Empty state: point at the folder instead of showing a blank grid.
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.files.length === 0
            Column {
                anchors.centerIn: parent
                width: Math.min(parent.width, 260)
                spacing: Theme.spacing
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: Icons.folder
                    color: Theme.fgDim
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fs(3)
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "No custom wallpapers"
                    color: Theme.fg
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize
                    font.bold: true
                }
                Text {
                    width: parent.width
                    text: "Add images or videos to " + root.shortDir(root.customDir) + ", then refresh."
                    color: Theme.fgDim
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize - 2
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                }
                AppButton {
                    anchors.horizontalCenter: parent.horizontalCenter
                    icon: Icons.refresh
                    text: "Refresh"
                    tooltipText: "Rescan " + root.shortDir(root.customDir)
                    onClicked: WallpaperService.refresh()
                }
            }
        }
    }
}
