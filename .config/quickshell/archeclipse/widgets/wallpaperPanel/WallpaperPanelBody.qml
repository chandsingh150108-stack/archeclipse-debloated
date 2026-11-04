import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtMultimedia
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.theme
import qs.services
import qs.widgets.shared

// Pick a wallpaper per workspace or the greeter background, browse/add/delete; hosted by
// WallpaperIsland in the main pill. Previews render the original files, no thumbnails.
Item {
    id: root

    // Island owner passes the bar's monitor; falls back to focused.
    property string monitorName: ""
    readonly property string effectiveMonitor: root.monitorName || Registry.monitorName

    // No implicitWidth: the host owns the width (the bar reads the island's implicitWidth), so
    // a value here is inert. Height is content-driven — mainCol has no margin, so its is the body's.
    implicitHeight: mainCol.implicitHeight

    readonly property string home: Quickshell.env("HOME")
    // WallEclipse CLI: `set <monitor> <ws> <path>` and `transition [slide|fade]` (persisted
    // daemon-side). The daemon re-reads config per event, so "reload" is just a health-check.
    readonly property string walleclipseBin: "walleclipse"

    function isVideoFile(file) {
        return WallpaperService.isVideoFile(file);
    }

    function isGifFile(file) {
        return /\.gif$/i.test(String(file || ""));
    }

    function isAnimatedPreviewFile(file) {
        return root.isVideoFile(file) || root.isGifFile(file);
    }

    // ---------------------------------------------------------------- state

    readonly property var targetTypes: ["workspace", "greeter"]
    property string targetType: "workspace"
    property int selectedWorkspaceId: 1
    // Fixed filename the greeter reads, overwritten in place on every set — so the tile loads
    // it cache:false and reloads explicitly, never a cached static source.
    readonly property string greeterPath: "/etc/xdg/quickshell/archeclipse-greeter/greeter-wallpaper"
    readonly property string greeterThemePath: "/etc/xdg/quickshell/archeclipse-greeter/colors.scss"
    readonly property string greeterThemeCache: root.home + "/.cache/archeclipse-greeter-theme"
    readonly property string greeterThemeConfig: root.home + "/.config/quickshell/archeclipse-greeter/greeter-theme-config"
    readonly property string greeterPaletteNormalizer: root.home + "/.config/quickshell/archeclipse/scripts/normalize-greeter-palette.py"
    readonly property string greeterSource: "file://" + root.greeterPath
    property string _pendingGreeterThemePath: ""
    property string _greeterThemeWallpaper: ""
    // Re-read the greeter file from disk (same-URL assignments don't
    // reload, so clear first and restore deferred past the cancel).
    function refreshGreeterTile() {
        greeterImg.source = "";
        Qt.callLater(() => greeterImg.source = root.greeterSource);
    }

    // Phased progress label (no spinner): searching/downloading/setting/deleting/adding and so
    // on; success and error auto-reset to idle after 1.5s.
    property string progressStatus: "idle"
    readonly property string progressText: {
        switch (root.progressStatus) {
        case "searching":
            return "Searching…";
        case "downloading":
            return "Downloading…";
        case "setting":
            return "Setting…";
        case "deleting":
            return "Deleting…";
        case "adding":
            return "Adding…";
        case "reloading":
            return "Reloading…";
        case "loading":
            return "Working…";
        case "success":
            return "Done";
        case "error":
            return "Failed";
        default:
            return "";
        }
    }
    readonly property string progressColor: {
        if (root.progressStatus === "success")
            return Theme.fg;
        if (root.progressStatus === "error")
            return Theme.color1;
        if (root.progressStatus === "idle")
            return Theme.fgDim;
        return Theme.accent;
    }
    function setProgress(status) {
        progressStatus = status;
        if (status === "success" || status === "error")
            progressResetTimer.restart();
    }
    Timer {
        id: progressResetTimer
        interval: 1500
        onTriggered: root.progressStatus = "idle"
    }

    // Shared store fetched at boot: WallpaperService owns the category map, thumb manifest and
    // aspect cache, and this body binds read-only so every monitor shares one scan.
    readonly property var wallpapers: WallpaperService.wallpapers
    readonly property var categories: Object.keys(wallpapers)
    // Single source of truth: Settings.wallpaperCategory, never assigned locally so it cannot
    // desync — writers go through Settings.updateSetting and every reader follows the binding.
    readonly property string selectedCategory: Settings.wallpaperCategory
    // Self-heal a saved category whose dir was deleted, gated on ready + non-empty so a fast
    // fetch cannot clobber the saved value before Settings.reload() adopts the file.
    function validateCategory() {
        if (!Settings.ready || root.categories.length === 0)
            return;
        if (!root.categories.includes(Settings.wallpaperCategory))
            Settings.updateSetting("wallpaperSwitcher.category", root.categories[0]);
    }
    // ComboBox resets currentIndex on model replacement (breaking any binding), so re-sync
    // imperatively, deferred past its own model-reset handling.
    function syncCategoryCombo() {
        Qt.callLater(() => {
            const i = root.categories.indexOf(root.selectedCategory);
            if (categoryCombo.currentIndex !== i)
                categoryCombo.currentIndex = i;
        });
    }
    Connections {
        target: Settings
        function onWallpaperCategoryChanged() {
            root.validateCategory();
            root.syncCategoryCombo();
        }
    }
    onCategoriesChanged: {
        root.validateCategory();
        root.syncCategoryCombo();
    }
    readonly property var selectedWallpapers: wallpapers[selectedCategory] ?? []
    // Capture must wait for data/thumbnail generation and masonry aspect updates;
    // CaptureIpc separately checks instantiated tiles (including opacity-zero ones).
    readonly property bool captureReady: !WallpaperService.fetchProc.running && !WallpaperService.thumbProc.running && !WallpaperService._thumbPending && Object.keys(WallpaperService._pendingAspect).length === 0 && (progressStatus === "idle" || progressStatus === "success") && selectedWallpapers.length > 0
    // Exposed for Ipc wallpaperDiag ("strip" query) and tests.
    readonly property alias wallStrip: wallScroll
    // Test hook for the "stripdeep" diag: lets automation walk the local
    // masonry geometry (rows, cellX/cellW, inWindow) without a mouse.
    readonly property alias localMasonry: localMasonry

    // Local-only browser: folder categories from the shared store.
    // Workspace-switch transition (slide default, fade optional): Settings.wallpaperTransition
    // is the source of truth, the daemon keeps its own copy, and setTransition() reloads it.
    readonly property var transitionTypes: ["slide", "fade"]
    readonly property string transition: Settings.wallpaperTransition

    // Shared masonry (both providers): exact results height from rows × tile height plus gaps;
    // tile widths come from aspect ratios, never the viewport.
    readonly property real resultsH: Math.max(1, Settings.wallpaperMasonryRows) * Settings.wallpaperTileSize + (Math.max(1, Settings.wallpaperMasonryRows) - 1) * 6
    function setMasonryRows(n) {
        Settings.updateSetting("wallpaperSwitcher.masonryRows", Math.min(4, Math.max(1, n)));
    }
    // Decoded-aspect cache in the shared store, reassigned (not mutated) so the masonry
    // recomputes; unknown paths fall back to 16:9 and settle once their thumb decodes.
    readonly property var localAspect: WallpaperService.localAspect
    function localAspectOf(path) {
        return WallpaperService.localAspectOf(path);
    }
    // Batched aspect reports live in the service (thumbs decode in a
    // storm on open); the service adopts once 250ms after last report.
    readonly property var _pendingAspect: WallpaperService._pendingAspect
    function noteLocalAspect(path, ratio) {
        WallpaperService.noteLocalAspect(path, ratio);
    }

    // First-frame thumbnails for video tiles live in the shared store
    // (adopted from WallpaperService's background ffmpeg queue).
    readonly property var thumbMap: WallpaperService.thumbMap
    function thumbFor(path) {
        return WallpaperService.thumbFor(path);
    }

    // The category combo opens a popup (separate window): while it is up the island is
    // not hovered, so its hover pin would otherwise expire mid-pick. Wired from the pin.
    readonly property bool comboPopupOpen: categoryCombo.popupHovered

    property var currentWallpapers: []           // path per workspace index, this monitor

    Component.onCompleted: {
        // Shared store is primed at shell boot; ensure it here too for
        // island-first creation paths, then load this monitor's current.
        WallpaperService.start();
        // The real monitor name arrives in onLoaded (after onCompleted): waiting avoids the
        // Registry fallback resolving wrong and a stale run swallowing the corrected fetch.
        if (root.monitorName !== "")
            fetchCurrentWallpapers();
        const ws = Hyprland.focusedWorkspace;
        if (ws)
            root.selectedWorkspaceId = ws.id;
    }

    // Best-effort: a fire-and-forget spawn during teardown may not survive, so the daemon's own
    // 5s preview watchdog is the real guarantee when the island goes away.
    Component.onDestruction: {
        previewDwell.stop();
        root.clearPreview();
    }

    // Hosts call this when the body becomes visible.
    function refresh() {
        WallpaperService.refresh();
        fetchCurrentWallpapers();
        root.refreshGreeterTile();
    }

    // Re-fetch when the real monitor name arrives (onLoaded is after onCompleted). Restart, not
    // start, so a stale in-flight run for the previous monitor cannot deliver after us.
    onMonitorNameChanged: {
        if (root.monitorName !== "") {
            // The overlay is bound to the monitor that was hovered; drop it
            // before the new monitor's fetch takes over.
            root.clearPreview();
            restartCurrentFetch();
        }
    }

    // Keep the selected workspace synced to whatever's focused when the
    // switcher opens.
    Connections {
        target: Hyprland
        function onFocusedWorkspaceChanged() {
            const ws = Hyprland.focusedWorkspace;
            if (ws)
                root.selectedWorkspaceId = ws.id;
        }
    }

    function notifyError(context, err) {
        setProgress("error");
        console.warn("[WallpaperSwitcher]", context, err);
        Notifications.notify({
            summary: "Error",
            body: String(err)
        }); // adjust to your notify service
    }

    // ---------------------------------------------------------- data fetch
    // Category map + thumbs come from WallpaperService (boot); this body keeps only --current.
    function fetchWallpapers() {
        WallpaperService.refresh();
    }

    Process {
        id: fetchCurrentProc
        // Compat flag: bodies bind `fetchCurrentProc.running` for readiness. No declarative
        // command — launcher functions assign it explicitly (see restartCurrentFetch).
        property bool running: false
    }
    // --current, QML-native: reads defaults.conf (`key=path`) via a one-shot FileView — one
    // reader per fetch (a reused one fires loaded only once); _currentSeq drops stale deliveries.
    property var _currentReader: null
    property int _currentSeq: 0
    function _parseCurrentDefaults(text) {
        // Mirrors the shell `while read` + sed + xargs: split at the first '=', expand a literal
        // $HOME prefix, trim whitespace. The trailing-newline artifact yields no iteration.
        const out = [];
        const raw = String(text || "").split("\n");
        if (raw.length > 0 && raw[raw.length - 1] === "")
            raw.pop();
        for (let i = 0; i < raw.length; i++) {
            const eq = raw[i].indexOf("=");
            let p = eq === -1 ? "" : raw[i].slice(eq + 1);
            if (p.indexOf("$HOME") === 0)
                p = root.home + p.slice(5);
            out.push(p.trim().split(/\s+/).join(" "));
        }
        return out;
    }
    function _adoptCurrent(seq, text) {
        if (seq !== root._currentSeq)
            return;
        try {
            root.currentWallpapers = root._parseCurrentDefaults(text).map(String);
        } catch (e) {
            root.notifyError("fetching current wallpapers", e);
        }
    }
    function _readCurrentFor(monitor) {
        if (root._currentReader) {
            root._currentReader.destroy();
            root._currentReader = null;
        }
        root._currentSeq++;
        if (!monitor) {
            root.currentWallpapers = [];
            return;
        }
        const seq = root._currentSeq;
        const p = root.home + "/.config/walleclipse/config/" + monitor + "/defaults.conf";
        const esc = p.split("\\").join("\\\\").split('"').join('\\"');
        try {
            root._currentReader = Qt.createQmlObject('import Quickshell.Io; FileView { path: "' + esc + '"; watchChanges: false; printErrors: false;' + ' onLoaded: root._adoptCurrent(' + seq + ', text());' + ' onLoadFailed: root._adoptCurrent(' + seq + ', "") }', root);
        } catch (e) {
            root._adoptCurrent(seq, "");
        }
    }
    function fetchCurrentWallpapers() {
        root._readCurrentFor(root.effectiveMonitor);
    }
    // Superseding restart: a boot-prime run may still be in flight and running=true is a no-op.
    // Build the command from root.monitorName, NOT effectiveMonitor (still stale in the handler).
    function restartCurrentFetch() {
        root._readCurrentFor(root.monitorName);
    }

    // ----------------------------------------------------------- set/apply

    Process {
        id: setProc
        onExited: code => {
            if (code === 0) {
                root.fetchCurrentWallpapers();
                // The greeter path is overwritten in place: re-read it so
                // the indicator tile shows the wallpaper just installed.
                if (root._pendingTarget === "greeter")
                    root.refreshGreeterTile();
                const target = root._pendingTarget;
                root._pendingTarget = "";
                if (target === "greeter") {
                    const wallpaper = root._pendingGreeterThemePath;
                    root._pendingGreeterThemePath = "";
                    root.regenGreeterTheme(wallpaper);
                    return;
                }
                // Share the global theme: regenerate cwal colors from the wallpaper (coloreclipse
                // wal honors autocolor), only for a workspace target with dynamicThemeColors.
                if (root._pendingThemeRegen !== "")
                    root.regenTheme(root._pendingThemeRegen);
                else
                    root.setProgress("success");
            } else {
                root._pendingThemeRegen = "";
                root._pendingTarget = "";
                root._pendingGreeterThemePath = "";
                root.setProgress("error");
            }
        }
    }

    // Single-quote a shell arg (wallpaper dirs contain spaces/apostrophes).
    function shq(s) {
        return "'" + String(s).replace(/'/g, "'\\''") + "'";
    }
    function commandFor(target, path) {
        switch (target) {
        case "greeter":
            // Fixed filename the greeter reads (Ready-gated Image): copy + world-read bit via
            // pkexec since the mirror is root-managed; excluded from sync --delete.
            return ["pkexec", "bash", "-c", `cp ${shq(path)} /etc/xdg/quickshell/archeclipse-greeter/greeter-wallpaper && chmod a+r /etc/xdg/quickshell/archeclipse-greeter/greeter-wallpaper`];
        default:
            // workspace (WallEclipse arg order: set <monitor> <ws> <path>)
            return [root.walleclipseBin, "set", root.effectiveMonitor, String(root.selectedWorkspaceId), path];
        }
    }

    function applyWallpaper(path) {
        // One at a time: setProc consumes the pending-_ values from the last
        // call, so a second apply mid-flight would overwrite the first's.
        if (setProc.running)
            return;
        // A set supersedes any live hover preview: the daemon cuts it too, but clearing first
        // leaves no frame of stale preview over the incoming wallpaper.
        root.clearPreview();
        setProgress("setting");
        root._pendingTarget = root.targetType;
        root._pendingThemeRegen = (root.targetType === "workspace" && Settings.dynamicThemeColors) ? path : "";
        root._pendingGreeterThemePath = root.targetType === "greeter" ? String(path) : "";
        setProc.command = commandFor(root.targetType, path);
        setProc.running = true;
    }

    // Fullscreen hover previews clear on leave: WallEclipse for stills, WallpaperAnimatedPreview
    // for GIFs/videos. A daemon-down ERR is ignored; show/clear requests are serialized.
    property int _previewSeq: 0
    property string _previewPath: ""
    property string _previewMonitor: ""
    readonly property string animatedPreviewPath: BarState.stateFor(root.monitorName) === "wallpaper" && root.isAnimatedPreviewFile(root._previewPath) ? root._previewPath : ""
    property string _previewCommandPath: ""
    property string _previewCommandMonitor: ""
    property string _previewSentPath: ""
    property string _previewSentMonitor: ""
    property bool _previewCommandSent: false
    // Hover dwell: preview only once the cursor settles, so sweeping the strip fires nothing and
    // no per-tile fade is allocated. Raise previewDwellMs to make it lazier.
    readonly property int previewDwellMs: 1000
    property string _dwellPath: ""
    function hoverPreview(path) {
        if (!path || !root.effectiveMonitor)
            return;
        root._dwellPath = String(path);
        previewDwell.restart();
    }
    function leavePreview(path) {
        if (root._dwellPath === String(path)) {
            previewDwell.stop();
            root._dwellPath = "";
        }
        if (root._previewPath === String(path))
            root.clearPreview(false);
    }
    Timer {
        id: previewDwell
        interval: root.previewDwellMs
        onTriggered: {
            const p = root._dwellPath;
            root._dwellPath = "";
            if (p !== "")
                root.previewWallpaper(p);
        }
    }
    function previewWallpaper(path) {
        const monitor = root.effectiveMonitor;
        if (!path || !monitor || BarState.stateFor(root.monitorName) !== "wallpaper")
            return;
        root._previewSeq += 1;
        root._previewPath = String(path);
        root._previewMonitor = monitor;
        // WallEclipse previews static wallpapers as a still; animated files use the per-monitor
        // QML overlay instead, clearing any static preview underneath it.
        root.requestPreviewCommand(root.isAnimatedPreviewFile(root._previewPath) ? "" : root._previewPath, monitor);
    }

    // Serialize preview/clear CLI requests: separate short-lived clients can otherwise reach the
    // daemon out of order when the pointer leaves mid-request.
    function requestPreviewCommand(path, monitor) {
        root._previewCommandPath = String(path);
        root._previewCommandMonitor = String(monitor);
        root.pumpPreviewCommand();
    }
    function pumpPreviewCommand() {
        if (previewCommand.running || root._previewCommandMonitor === "")
            return;
        if (root._previewCommandSent && root._previewCommandPath === root._previewSentPath && root._previewCommandMonitor === root._previewSentMonitor)
            return;

        root._previewSentPath = root._previewCommandPath;
        root._previewSentMonitor = root._previewCommandMonitor;
        root._previewCommandSent = true;
        previewCommand.command = root._previewCommandPath === "" ? [root.walleclipseBin, "preview-clear", root._previewCommandMonitor] : [root.walleclipseBin, "preview", root._previewCommandMonitor, root._previewCommandPath];
        previewCommand.running = true;
    }
    Process {
        id: previewCommand
        onExited: root.pumpPreviewCommand()
    }

    function clearPreview(cancelDwell) {
        if (cancelDwell !== false) {
            previewDwell.stop();
            root._dwellPath = "";
        }
        root._previewSeq += 1;
        root._previewPath = "";
        const monitor = root._previewMonitor || root._previewCommandMonitor || root.effectiveMonitor;
        root._previewMonitor = "";
        if (monitor)
            root.requestPreviewCommand("", monitor);
    }
    function clearPreviewIfInactive() {
        if (BarState.stateFor(root.monitorName) !== "wallpaper")
            root.clearPreview();
    }
    Connections {
        target: BarState
        function onPanelStatesByMonitorChanged() {
            root.clearPreviewIfInactive();
        }
        function onActiveStatesChanged() {
            root.clearPreviewIfInactive();
        }
    }

    // ---- global theme sharing (coloreclipse wal -> cwal colors.scss -> Theme) ----
    property string _pendingThemeRegen: ""
    property string _pendingTarget: ""
    Process {
        id: themeProc
        onExited: code => {
            // Variant may have auto-switched (autovariant) — re-read it so
            // the ControlPanel toggle and GlobalTheme state stay correct.
            GlobalTheme.refresh();
            if (code === 0)
                root.setProgress("success");
            else
                root.notifyError("updating theme colors", "coloreclipse wal failed");
        }
    }
    function regenTheme(path) {
        root._pendingThemeRegen = "";
        themeProc.command = ["coloreclipse", "wal", path];
        themeProc.running = true;
    }

    Process {
        id: greeterThemeProc
        onExited: code => {
            if (code === 0) {
                greeterPaletteNormalizeProc.command = ["python3", root.greeterPaletteNormalizer, root._greeterThemeWallpaper, root.greeterThemeCache + "/coloreclipse/colors.scss"];
                greeterPaletteNormalizeProc.running = true;
            } else {
                root.notifyError("generating greeter theme", "coloreclipse wal failed (exit " + code + ")");
            }
        }
    }
    Process {
        id: greeterPaletteNormalizeProc
        onExited: code => {
            if (code === 0) {
                greeterPaletteInstallProc.command = ["pkexec", "install", "-m", "0644", root.greeterThemeCache + "/coloreclipse/colors.scss", root.greeterThemePath];
                greeterPaletteInstallProc.running = true;
            } else {
                root.notifyError("normalizing greeter theme", "could not match the palette to the wallpaper (exit " + code + ")");
            }
        }
    }
    Process {
        id: greeterPaletteInstallProc
        onExited: code => {
            if (code === 0)
                root.setProgress("success");
            else
                root.notifyError("installing greeter theme", "could not update the greeter palette (exit " + code + ")");
        }
    }
    function regenGreeterTheme(path) {
        if (!path) {
            root.notifyError("generating greeter theme", "no wallpaper path was provided");
            return;
        }
        root._greeterThemeWallpaper = String(path);
        greeterThemeProc.command = ["env", "XDG_CONFIG_HOME=" + root.greeterThemeConfig, "XDG_CACHE_HOME=" + root.greeterThemeCache, "coloreclipse", "wal", path];
        greeterThemeProc.running = true;
    }

    function setRandomWallpaper() {
        const list = root.selectedWallpapers;
        if (list.length === 0)
            return;
        applyWallpaper(list[Math.floor(Math.random() * list.length)]);
    }

    // -------------------------------------------------------------- delete

    Process {
        id: deleteProc
        onExited: code => {
            root.fetchWallpapers();
            if (code === 0) {
                Notifications.notify({
                    summary: "Success",
                    body: "Wallpaper deleted successfully!"
                });
                root.setProgress("success");
            } else {
                root.setProgress("error");
            }
        }
    }
    function deleteWallpaper(path) {
        if (deleteProc.running)
            return;
        setProgress("deleting");
        deleteProc.command = ["bash", "-c", `rm -f ${JSON.stringify(path)}`];
        deleteProc.running = true;
    }
    function copyWallpaperPath(path) {
        const p = Qt.createQmlObject('import Quickshell.Io; Process {}', root);
        const label = "Wallpaper path";
        p.command = ["bash", "-c", "echo -n " + JSON.stringify(String(path)) + " | wl-copy"];
        p.running = true;
        p.exited.connect(function (code) {
            if (code === 0)
                Notifications.notify({
                    summary: "Copied to Clipboard",
                    body: label + " copied successfully!"
                });
            else
                Notifications.notify({
                    summary: "Error",
                    body: "Failed to copy to clipboard"
                });
            p.destroy();
        });
    }

    // ----------------------------------------------------------- daemon reload

    property int _reloadAttempts: 0
    Process {
        id: reloadProc
        onExited: code => {
            if (code === 0) {
                root._reloadAttempts = 0;
                root.fetchWallpapers();
                root.setProgress("success");
            } else if (root._reloadAttempts < 1) {
                // Daemon may be dead: start it, then retry once.
                root._reloadAttempts += 1;
                startProc.running = true;
            } else {
                root._reloadAttempts = 0;
                root.setProgress("error");
            }
        }
    }
    Process {
        id: startProc
        command: ["bash", "-c", "nohup walleclipse >/tmp/walleclipse-daemon-out.log 2>&1 & sleep 3"]
        onExited: code => {
            if (code === 0)
                reloadProc.running = true;
            else {
                root._reloadAttempts = 0;
                root.setProgress("error");
            }
        }
    }
    function reloadDaemon() {
        // WallEclipse re-reads config + re-applies current on reload.
        root._reloadAttempts = 0;
        setProgress("reloading");
        reloadProc.command = [root.walleclipseBin, "reload"];
        reloadProc.running = true;
    }

    // Persist UI-side (settings.json) and daemon-side (`walleclipse transition`, durable), then
    // reload so the change takes effect immediately — the reload applies with a fade.
    Process {
        id: transitionProc
        onExited: code => {
            if (code === 0)
                root.reloadDaemon();
            else
                root.setProgress("error");
        }
    }
    function setTransition(name) {
        if (name !== "slide" && name !== "fade")
            return;
        Settings.updateSetting("wallpaperSwitcher.transition", name);
        setProgress("reloading");
        transitionProc.command = [root.walleclipseBin, "transition", name];
        transitionProc.running = true;
    }

    // --------------------------------------------------------- add wallpaper

    Process {
        id: pickProc
        command: ["zenity", "--file-selection", "--title=Select Wallpaper", "--file-filter=Images (png, jpg, webp, gif, mp4) | *.png *.jpg *.jpeg *.webp *.gif *.mp4"]
        stdout: StdioCollector {
            onStreamFinished: {
                const path = text.trim();
                if (path.length > 0)
                    root.importWallpaper(path);
                else
                    root.progressStatus = "idle";
            }
        }
        onExited: code => {
            // zenity exits 1 on Cancel — that's not a real error.
            if (code !== 0 && code !== 1)
                root.setProgress("error");
        }
    }
    function pickWallpaper() {
        pickProc.running = true;
    }

    Process {
        id: importProc
        onExited: code => {
            if (code === 0) {
                Notifications.notify({
                    summary: "Success",
                    body: "Wallpaper added successfully!"
                });
                root.fetchWallpapers();
                root.setProgress("success");
            } else {
                root.notifyError("adding wallpaper", "copy step failed");
            }
        }
    }
    function importWallpaper(sourcePath) {
        if (importProc.running)
            return;
        setProgress("adding");
        const targetDir = root.home + "/.config/wallpapers/custom";
        const basename = sourcePath.split("/").pop();
        const targetPath = targetDir + "/" + basename;

        importProc.command = ["bash", "-c", `mkdir -p ${JSON.stringify(targetDir)} && ` + `cp -- ${JSON.stringify(sourcePath)} ${JSON.stringify(targetPath)}`];
        importProc.running = true;
    }

    // cached file sizes for tooltip (path -> bytes), one stat per path.
    // Path passed as argv (no shell quoting) so names with quotes still work.
    property var fileSizes: ({})
    function getFileSize(path) {
        if (root.fileSizes[path] !== undefined)
            return root.fileSizes[path];
        const p = Qt.createQmlObject('import Quickshell.Io; Process { stdout: StdioCollector {} }', root);
        p.command = ["stat", "-c", "%s", path];
        p.running = true;
        p.stdout.onStreamFinished.connect(function () {
            const sz = parseInt(p.stdout.text.trim()) || 0;
            const fs = root.fileSizes;
            fs[path] = sz;
            root.fileSizes = fs;
            p.destroy();
        });
        return 0;
    }
    function formatBytes(bytes) {
        if (bytes === 0)
            return "N/A";
        const units = ["B", "KB", "MB", "GB"];
        let i = 0;
        let b = bytes;
        while (b >= 1024 && i < units.length - 1) {
            b /= 1024;
            i++;
        }
        return b.toFixed(i === 0 ? 0 : 1) + " " + units[i];
    }

    // ------------------------------------------------------------------ UI

    Rectangle {
        id: wallpaperSwitcher
        anchors.fill: parent
        color: "transparent"
        radius: Theme.radius

        ColumnLayout {
            id: mainCol
            anchors.fill: parent
            // No outer margin: Theme.islandPad is the only inset between pill edge and content —
            // adding one here stacks a second (this body used to add 12).
            spacing: Theme.spacing

            // per-workspace current wallpaper strip — tiles scroll so 11+ workspaces glide
            // instead of overflowing; greeter + separator stay fixed outside the flickable.
            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                spacing: Theme.spacing
                // Greeter (login) wallpaper indicator — first tile, lock in center.
                Rectangle {
                    id: greeterTile
                    width: 100
                    height: 66
                    radius: Theme.radius
                    color: Theme.onMediaBg
                    border.width: root.targetType === "greeter" ? 2 : 0
                    border.color: Theme.accent

                    AppImage {
                        id: greeterImg
                        anchors.fill: parent
                        anchors.margins: 2
                        cache: false
                        source: root.greeterSource
                        sourceWidth: greeterTile.width
                    }
                    Rectangle {
                        anchors.centerIn: parent
                        width: 28
                        height: 28
                        radius: width / 2
                        color: Theme.muted
                        opacity: Theme.opacity.soft
                        Text {
                            anchors.centerIn: parent
                            text: Icons.lock
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSizeLarge
                            color: Theme.onMediaInk
                        }
                    }
                    MouseArea {
                        id: greeterMa
                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.LeftButton
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.targetType = "greeter"
                    }
                    AppTooltip {
                        visible: greeterMa.containsMouse
                        delay: 400
                        text: "Greeter wallpaper.\nClick to target greeter."
                    }
                }
                // Separator between the greeter tile and the workspace tiles.
                Rectangle {
                    Layout.preferredWidth: 2
                    Layout.preferredHeight: 48
                    Layout.alignment: Qt.AlignVCenter
                    color: Theme.border
                }
                // Workspace tiles only — the scrollable part.
                SmoothFlickable {
                    id: wsStripScroll
                    // Content-sized when narrow (group stays centered), capped at the leftover
                    // island width when wide (greeter 100 + separator 2 + 2x spacing 10).
                    Layout.preferredWidth: Math.max(0, Math.min(wsStripRow.width, mainCol.width - 122))
                    Layout.preferredHeight: 66
                    flickableDirection: Flickable.HorizontalFlick
                    contentWidth: wsStripRow.width
                    contentHeight: height
                    ScrollBar.horizontal: ScrollBar {
                        policy: ScrollBar.AsNeeded
                    }

                    Row {
                        id: wsStripRow
                        height: wsStripScroll.height
                        spacing: Theme.spacing
                        // Content-driven width, never bound to the viewport (polish-loop pitfall);
                        // left-origin so tiles hug the separator instead of centering.
                        Repeater {
                            model: root.currentWallpapers
                            delegate: Rectangle {
                                id: wsTile
                                required property string modelData
                                required property int index
                                readonly property bool isFocused: Hyprland.focusedWorkspace?.id === index + 1
                                // Original for images, first-frame thumb for videos: a live AppVideo here
                                // decoded every workspace video forever (~10% CPU and ~1GB RSS each).
                                readonly property string wsSource: wsTile.modelData === "" ? "" : (root.isVideoFile(wsTile.modelData) ? root.thumbFor(wsTile.modelData) : wsTile.modelData)

                                width: 100
                                height: 66
                                radius: Theme.radius
                                color: modelData === "" ? "black" : "transparent"
                                border.width: isFocused ? 1 : 0
                                border.color: Theme.muted

                                AppImage {
                                    visible: wsTile.modelData !== ""
                                    anchors.fill: parent
                                    anchors.margins: 2
                                    // Native preview: original file decoded near tile size (async +
                                    // cached in AppImage). Videos use the first-frame thumb, no decoder.
                                    source: wsTile.wsSource === "" ? "" : "file://" + wsTile.wsSource
                                    sourceWidth: wsTile.width
                                    badges: [(wsTile.index + 1).toString()]
                                }
                                Text {
                                    // Video icon until the background thumb run delivers a frame (or
                                    // permanently when no thumb exists).
                                    visible: wsTile.modelData !== "" && root.isVideoFile(wsTile.modelData) && wsTile.wsSource === ""
                                    anchors.centerIn: parent
                                    text: Icons.video
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fs(1.67)
                                    color: Theme.fgDim
                                }
                                Text {
                                    visible: wsTile.modelData === ""
                                    anchors.centerIn: parent
                                    text: "No Wallpaper"
                                    color: Theme.muted
                                    font.family: Theme.fontFamily
                                }
                            }
                        }
                    }
                }
            }

            // action bar — wrapped so radius / bg / border apply as one pill
            Rectangle {
                Layout.alignment: Qt.AlignHCenter
                implicitWidth: actionBar.implicitWidth + 16
                implicitHeight: actionBar.implicitHeight + 10
                radius: Theme.radius
                color: Theme.surface

                clip: true

                RowLayout {
                    id: actionBar
                    anchors.centerIn: parent
                    spacing: Theme.spacing

                    AppSegmentedControl {
                        model: root.targetTypes
                        currentIndex: root.targetTypes.indexOf(root.targetType)
                        cellHPadding: 8
                        cellVPadding: 4
                        onActivated: (i, v) => root.targetType = v
                    }

                    // Workspace-switch transition: slide (default) or fade, persisted daemon-side
                    // and followed by a reload so it applies with a fade right away.
                    AppSegmentedControl {
                        model: root.transitionTypes
                        currentIndex: root.transitionTypes.indexOf(root.transition)
                        cellHPadding: 8
                        cellVPadding: 4
                        onActivated: (i, v) => root.setTransition(v)
                    }


                    AppComboBox {
                        id: categoryCombo
                        objectName: "categoryCombo"
                        model: root.categories
                        Layout.preferredHeight: 26
                        currentIndex: root.categories.indexOf(root.selectedCategory)
                        onActivated: i => Settings.updateSetting("wallpaperSwitcher.category", root.categories[i])
                    }

                    AppButton {
                        tooltipText: "Set a random wallpaper from this view"
                        text: "Random"
                        Layout.preferredHeight: 26
                        onClicked: root.setRandomWallpaper()
                    }
                    AppButton {
                        tooltipText: "Reload the wallpaper daemon"
                        text: "Reload"
                        Layout.preferredHeight: 26
                        onClicked: root.reloadDaemon()
                    }
                    AppButton {
                        tooltipText: "Pick a wallpaper image to add"
                        text: "Add…"
                        Layout.preferredHeight: 26
                        onClicked: root.pickWallpaper()
                    }

                    // Shared masonry view (both providers, persisted).
                    AppButton {
                        text: "‹"
                        tooltipText: "Fewer masonry rows"
                        enabled: Settings.wallpaperMasonryRows > 1
                        Layout.preferredHeight: 26
                        onClicked: root.setMasonryRows(Settings.wallpaperMasonryRows - 1)
                    }
                    Text {
                        text: Settings.wallpaperMasonryRows + (Settings.wallpaperMasonryRows === 1 ? " row" : " rows")
                        color: Theme.fg
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 2
                    }
                    AppButton {
                        text: "›"
                        tooltipText: "More masonry rows"
                        enabled: Settings.wallpaperMasonryRows < 4
                        Layout.preferredHeight: 26
                        onClicked: root.setMasonryRows(Settings.wallpaperMasonryRows + 1)
                    }
                    AppSlider {
                        Layout.preferredWidth: 64
                        Layout.preferredHeight: 26
                        from: 80
                        to: 200
                        stepSize: 10
                        value: Settings.wallpaperTileSize
                        onValueChanged: {
                            // Same binding guard as the booru sliders: the settings write re-evaluates
                            // value to the same number, which must not write back in a loop.
                            const v = Math.round(value);
                            if (v === Settings.wallpaperTileSize)
                                return;
                            Settings.updateSetting("wallpaperSwitcher.tileSize", v);
                        }
                    }
                    Text {
                        text: Settings.wallpaperTileSize + "px"
                        color: Theme.fgDim
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 2
                    }

                    Text {
                        // Phased progress text (replaces the spinner): fixed
                        // width so phase changes don't jitter the action bar.
                        width: 70
                        elide: Text.ElideRight
                        text: root.progressText
                        color: root.progressColor
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSize - 2
                    }
                }
            }


            // all wallpapers in the selected category — horizontal strip
            SmoothFlickable {
                id: wallScroll
                objectName: "wallStrip"
                Layout.fillWidth: true
                Layout.preferredHeight: root.resultsH
                flickableDirection: Flickable.HorizontalFlick
                contentWidth: localMasonry.contentWidth
                contentHeight: height
                ScrollBar.horizontal: ScrollBar {
                    policy: ScrollBar.AsNeeded
                }

                AppMasonryRow {
                    id: localMasonry
                    width: wallScroll.width
                    height: implicitHeight
                    rows: Settings.wallpaperMasonryRows
                    spacing: Theme.spacing
                    rowHeight: Settings.wallpaperTileSize
                    // Preserve the (alphabetically sorted) file order left-to-right instead of
                    // shortest-row bin-packing, which shuffled tiles as aspects refined.
                    balanceRows: false
                    model: root.selectedWallpapers
                    aspectRatio: function (path) {
                        return root.localAspectOf(path);
                    }
                    // Lazy window: instantiate only tiles near the viewport (fast open on 100+
                    // folders, decoders freed when scrolled away).
                    viewLeft: wallScroll.contentX - 700
                    viewRight: wallScroll.contentX + wallScroll.width + 700
                    buffer: 700
                    placeholder: Rectangle {
                        color: Theme.surface
                        radius: Theme.radius
                    }
                    delegate: Rectangle {
                        id: tile
                        // Plain (not required) modelData — the masonry pushes
                        // it via Loader onLoaded (same contract as AppMasonry).
                        property var modelData
                        // Masonry widths are always aspect-derived (a hover-expand would fight the
                        // layout); each thumb reports its decoded ratio back, refining the width.
                        width: localMasonry.widthFor(modelData)
                        height: localMasonry.rowHeight
                        // Fades in once the preview settles (image decoded or Error, video ready);
                        // modelData arrives via Loader push after creation, so every access is guarded.
                        readonly property string tileThumb: root.thumbFor(tile.modelData)
                        readonly property bool thumbSettled: (tile.modelData !== undefined && root.isVideoFile(tile.modelData)) ? (tile.previewing ? tileVideo.ready : (tile.tileThumb === "" || tileImg.status === Image.Ready || tileImg.status === Image.Error)) : (tileImg.status === Image.Ready || tileImg.status === Image.Error)
                        // Workspace badges: which workspaces use this wallpaper (top-right), shared
                        // by the still preview and the live video (only one is visible).
                        readonly property var badgeIds: {
                            const ids = [];
                            const cur = root.currentWallpapers;
                            for (let i = 0; i < cur.length; i++) {
                                if (cur[i] !== "" && cur[i] === tile.modelData)
                                    ids.push(String(i + 1));
                            }
                            return ids;
                        }
                        opacity: tile.thumbSettled ? 1 : 0
                        Behavior on opacity {
                            NumberAnimation {
                                duration: 250
                                easing.type: Easing.OutCubic
                            }
                        }
                        // Stagger timers and hover-expand are gone: widths
                        // are masonry-owned (see delegate header).
                        readonly property string fileName: tile.modelData === undefined ? "" : String(tile.modelData).split("/").pop()
                        // Two-step delete confirm: first click arms (trash ->
                        // check + red), second click deletes. Reset on leave.
                        property bool deleteArmed: false
                        Timer {
                            id: disarmTimer
                            interval: 3000
                            onTriggered: tile.deleteArmed = false
                        }
                        radius: Theme.radius
                        color: tileMa.containsMouse ? Theme.surfaceHover : Theme.surface
                        border.width: tileMa.containsMouse ? 2 : 0
                        border.color: Theme.muted

                        AppImage {
                            id: tileImg
                            anchors.fill: parent
                            // Zero inset so tiles read edge-to-edge like the booru masonry; the hover
                            // border overlaps the edge by design. Images decode the original file.
                            source: (tile.modelData === undefined) ? "" : (root.isVideoFile(tile.modelData) ? (tile.tileThumb !== "" ? "file://" + tile.tileThumb : "") : "file://" + tile.modelData)
                            // Decode at a stable width: sourceWidth following the aspect-derived width
                            // reloaded on every refine (flicker); the fixed rowHeight sizes it instead.
                            sourceWidth: Math.max(1, Math.round(Settings.wallpaperTileSize * 2))
                            badges: tile.badgeIds
                            animated: tileMa.containsMouse && tile.modelData !== undefined && root.isGifFile(tile.modelData)
                            onStatusChanged: {
                                if (tileImg.status === Image.Ready && tileImg.implicitImageWidth > 0 && tileImg.implicitImageHeight > 0)
                                    root.noteLocalAspect(tile.modelData, tileImg.implicitImageWidth / tileImg.implicitImageHeight);
                            }
                        }
                        // Live video preview: shared AppVideo, muted + looping, ON HOVER ONLY — a
                        // video folder opens ~25 tiles and autoplaying them all froze the panel.
                        readonly property bool previewing: tile.modelData !== undefined && root.isVideoFile(tile.modelData) && tileMa.containsMouse
                        AppVideo {
                            id: tileVideo
                            anchors.fill: parent
                            // Zero inset: parity with the still thumb (and thus
                            // the booru masonry gaps) — no ring on hover-expand.
                            visible: tile.previewing
                            source: tile.previewing ? tile.modelData : ""
                            active: tile.previewing
                            muted: true
                            fillMode: VideoOutput.PreserveAspectCrop
                            badges: tile.badgeIds
                            onReadyChanged: {
                                if (tileVideo.ready && tileVideo.videoRatio > 0)
                                    root.noteLocalAspect(tile.modelData, tileVideo.videoRatio);
                            }
                            onErrorOccurred: message => {
                                console.warn("[WallpaperSwitcher] video preview failed for " + tile.modelData + ": " + message);
                            }
                        }
                        Column {
                            // Idle fallback for videos: no thumb mapped yet (generator running) or
                            // the thumb failed — same icon look; hover swaps in the live preview.
                            visible: tile.modelData !== undefined && root.isVideoFile(tile.modelData) && !tile.previewing && (tile.tileThumb === "" || tileImg.status === Image.Error)
                            anchors.centerIn: parent
                            spacing: Theme.spacing
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: Icons.video
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fs(2)
                                color: Theme.fgDim
                            }
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: tile.fileName
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSize - 2
                                color: Theme.fgDim
                                elide: Text.ElideMiddle
                                width: Math.max(0, tile.width - 16)
                                horizontalAlignment: Text.AlignHCenter
                            }
                        }

                        // Hidden while the strip moves: a visible tooltip window sits under the cursor
                        // and swallows wheel events, killing the momentum glide.
                        AppTooltip {
                            visible: tileMa.containsMouse && !wallScroll.moving
                            delay: 400
                            text: `Click to set as ${root.targetType} wallpaper.\nRight-click to delete.\n${(tile.modelData !== undefined && root.isAnimatedPreviewFile(tile.modelData)) ? "Hover to preview.\n" : ""}${tile.fileName}\nSize: ${root.formatBytes(root.getFileSize(tile.modelData ?? ""))}`
                        }

                        MouseArea {
                            id: tileMa
                            anchors.fill: parent
                            hoverEnabled: true
                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                            cursorShape: Qt.PointingHandCursor
                            // Tiles cover the strip: let wheel fall through to the strip's
                            // SmoothWheelHandler so the horizontal glide receives it.
                            onWheel: wheel => wheel.accepted = false
                            onContainsMouseChanged: {
                                if (!containsMouse && !copyMa.containsMouse && !delMa.containsMouse)
                                    tile.deleteArmed = false;
                                if (containsMouse)
                                    root.hoverPreview(tile.modelData);
                                else
                                    root.leavePreview(tile.modelData);
                            }
                            onClicked: mouse => {
                                if (mouse.button === Qt.RightButton)
                                    root.deleteWallpaper(tile.modelData);
                                else
                                    root.applyWallpaper(tile.modelData);
                            }
                        }

                        // Local-only action overlay (top-left, badge-style): copy path + two-step
                        // delete; badges already occupy top-right. Above tileMa so clicks land.
                        Row {
                            anchors.top: parent.top
                            anchors.left: parent.left
                            anchors.margins: 4
                            spacing: Theme.spacing
                            readonly property bool hovered: tile.modelData !== undefined && (tileMa.containsMouse || copyMa.containsMouse || delMa.containsMouse)
                            opacity: hovered ? 1 : 0
                            visible: hovered || opacity > 0
                            Behavior on opacity {
                                Anim {
                                    type: Anim.FastEffects
                                }
                            }
                            Rectangle {
                                width: 24
                                height: 18
                                radius: Theme.radius
                                color: Theme.muted
                                opacity: Theme.opacity.soft
                                Text {
                                    anchors.centerIn: parent
                                    text: Icons.copy
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontSizeBadge
                                    color: Theme.onMediaInk
                                }
                                MouseArea {
                                    id: copyMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    acceptedButtons: Qt.LeftButton
                                    cursorShape: Qt.PointingHandCursor
                                    onWheel: wheel => wheel.accepted = false
                                    onClicked: mouse => {
                                        mouse.accepted = true;
                                        root.copyWallpaperPath(tile.modelData);
                                    }
                                }
                            }
                            Rectangle {
                                width: 24
                                height: 18
                                radius: Theme.radius
                                color: tile.deleteArmed ? Theme.color1 : Theme.muted
                                opacity: tile.deleteArmed ? 1.0 : 0.9
                                Text {
                                    anchors.centerIn: parent
                                    text: tile.deleteArmed ? Icons.check : Icons.trash
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontSizeBadge
                                    color: Theme.onMediaInk
                                }
                                MouseArea {
                                    id: delMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    acceptedButtons: Qt.LeftButton
                                    cursorShape: Qt.PointingHandCursor
                                    onWheel: wheel => wheel.accepted = false
                                    onContainsMouseChanged: {
                                        if (!containsMouse && !tileMa.containsMouse)
                                            tile.deleteArmed = false;
                                    }
                                    onClicked: mouse => {
                                        mouse.accepted = true;
                                        if (!tile.deleteArmed) {
                                            tile.deleteArmed = true;
                                            disarmTimer.restart();
                                        } else {
                                            disarmTimer.stop();
                                            tile.deleteArmed = false;
                                            root.deleteWallpaper(tile.modelData);
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

        }
    }
}
