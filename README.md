# archeclipse-debloated

A personal, de-anime'd fork of [**ArchEclipse**](https://github.com/AymanLyesri/ArchEclipse) by AymanLyesri — Arch + Hyprland + Quickshell desktop, trimmed down and extended with a local AI workflow. All credit for the base system goes upstream; this repo only carries the deviations listed below.

## What changed vs upstream

- **Left rail trimmed to 6 tabs.** `MangaViewer` and `Donations` are hidden behind `hiddenLeftPanelTabs` in `theme/Settings.qml` (delete a name there to bring a tab back — rail, tab order, IPC validator, and welcome tour all follow that one list).
- **BooruViewer → Wallpapers.** The left tab is now a flat grid over `~/.config/wallpapers/custom` only — no providers, search, tags, or paging. Clicking a tile sets it on the **focused workspace** (`walleclipse set <mon> <ws>`) and regenerates the palette (`coloreclipse wal`). The `BooruViewer` type itself stays for WaifuWidget's embedded viewer.
- **OpenCode in the ChatBot panel.** New `OpenCode` provider tab next to the OpenRouter models. A `main_opencode.py` bridge reuses the panel contract (same sessions, history, streaming bubble) and runs `opencode run --format json --agent plan` (read-only) in a fixed directory (`~/Chandd`). Model is configurable in Setting.
- **This fork is the deploy source.** `update.py`'s `REPO_URL` points here, and the `archeclipse` zsh override (machine-local, `~/.config/zsh/custom/local.zsh`) fetches the updater from this repo. The `plugins` update step defaults to off (hyprpm can't write its state here, and a failed step aborts the run before the bar reloads). Dynamic-cursors plugin config ships disabled for the same reason.
- **No anime defaults.** Waifu widget off, booru cache removed, neutral wallpaper, dark palette.

## Install / update

**Need:** Arch / Arch-based + Hyprland + Python 3.

Fresh machine (deploys this fork's dotfiles onto `$HOME`, installs packages):

```bash
python3 <(curl -fsSL https://raw.githubusercontent.com/chandsingh150108-stack/archeclipse-debloated/master/.config/hypr/maintenance/update.py)
```

Day to day (after placing the `archeclipse()` override in `~/.config/zsh/custom/local.zsh`):

```bash
archeclipse   # update from this fork
```

`$HOME` itself is the git worktree (`~/.git`, remote `origin` = this fork, `upstream` = AymanLyesri/ArchEclipse), so `git -C ~ status/diff/log` shows exactly what deviates. Untracked files (settings cache, `hyprland.conf`, wallpapers) survive every update.

## Receiving upstream changes

```bash
git -C ~ fetch upstream
git -C ~ merge upstream/master
git -C ~ push
```

Merge conflicts will land in the files this fork touches (`LeftIsland.qml`, `Settings.qml`, `SettingsWidget.qml`, `ChatBotWidget.qml`) — resolve, reload the bar, push.

## OpenCode provider notes

- Requires the `opencode` binary and a `~/Chandd` project directory (override both in Settings).
- Panel sessions map 1:1 to opencode sessions (`--session`), so they show up in `opencode session list` with a `panel-<id>` title.
- The plan agent is read-only: it can look at your files,but not edit or run commands.
- Context chips (workspace/window/clipboard/file) apply to OpenRouter only — opencode brings its own tools and cwd.
- Replies arrive whole, not token-by-token,, so it may feel slower but it's actually the same tks/s  (`opencode run` emits one `text` event per turn).



---

Forked from [AymanLyesri/ArchEclipse](https://github.com/AymanLyesri/ArchEclipse) — bugs in the base system belong upstream; bugs in the deviations above belong here.
