# Smux

Smux is a personal fork of [cmux](https://github.com/manaflow-ai/cmux), the native macOS terminal built on [Ghostty](https://github.com/ghostty-org/ghostty). It tracks upstream cmux releases and adds its own branding and a few renderer tweaks on top.

The original cmux README is kept in [`README.cmux.md`](README.cmux.md).

| | |
|---|---|
| App name | `Smux` |
| Bundle ID | `com.cmuxterm.app.debug.smux` |
| Based on | cmux `v0.65.2` |
| Upstream | `https://github.com/manaflow-ai/cmux` |

## What Smux changes

- **App icon:** new artwork in `AppIcon.icon/Assets/smux-art.png`, plus the regenerated PNGs in `Assets.xcassets/AppIcon.appiconset/`.
- **Xcode project:** `cmux.xcodeproj/project.pbxproj` adds `AppIcon.icon` to the app's resources as an Icon Composer icon.
- **Ghostty renderer:** `ghostty/src/renderer/generic.zig` and `ghostty/src/renderer/Thread.zig` are edited. These edits live in the `ghostty` submodule, so they need their own fork or patch file (see [Ghostty submodule](#ghostty-submodule)).

## Requirements

- macOS with full **Xcode 26** (see `.xcode-version`), opened once with its license accepted
- The Metal toolchain: `xcodebuild -downloadComponent MetalToolchain`
- **Zig:** `brew install zig`
- About 10 GB of free disk space for build caches

## Setup on a new Mac

```bash
git clone --recursive <your-smux-repo-url> smux
cd smux
./scripts/setup.sh        # checks Xcode/Metal and builds GhosttyKit.xcframework from ./ghostty
```

If you cloned without `--recursive`:

```bash
git submodule update --init --recursive
```

## Building

The Smux build is a tagged release build, which puts its output in `~/Library/Developer/Xcode/DerivedData/cmux-smux/`:

```bash
./scripts/reloads.sh --tag smux
```

The app ends up at:

```
~/Library/Developer/Xcode/DerivedData/cmux-smux/Build/Products/Release/Smux.app
```

Copy it to `/Applications` to install. See `CONTRIBUTING.md` and `./scripts/reload.sh --help` for the other build modes.

> Check this command the first time you build on a new machine. The exact steps that produced the original `Smux.app` weren't recorded.

## Updating from upstream cmux

```bash
git remote add upstream https://github.com/manaflow-ai/cmux.git   # once
git fetch upstream --tags
git rebase <new-cmux-tag>          # e.g. v0.66.0, or use: git merge <tag>
git submodule update --init --recursive
./scripts/setup.sh                 # rebuild GhosttyKit if ghostty moved
```

Conflicts usually show up in:

- `cmux.xcodeproj/project.pbxproj`: keep upstream's changes, then re-add the `AppIcon.icon` resource entries.
- `AppIcon.icon/` and `Assets.xcassets/AppIcon.appiconset/`: keep the Smux versions.
- `ghostty`: re-apply the renderer edits on top of the new submodule commit.

## Ghostty submodule

`ghostty` points at `https://github.com/manaflow-ai/ghostty.git`. The Smux renderer edits can't be pushed there, so use one of these:

1. **Fork it (recommended):** fork `manaflow-ai/ghostty`, commit the edits on a `smux` branch, then point the submodule at your fork:
   ```bash
   git config -f .gitmodules submodule.ghostty.url <your-ghostty-fork-url>
   git submodule sync
   ```
2. **Patch file:** keep the edits in this repo and apply them after each checkout:
   ```bash
   git -C ghostty diff > patches/ghostty-smux.patch    # save
   git -C ghostty apply ../patches/ghostty-smux.patch  # restore
   ```

## Installing Smux on another Mac

Smux is self-signed and not notarized by Apple, so macOS blocks it the first time it runs.

1. Open the `.dmg` and drag **Smux** into **Applications**, then eject the `.dmg`.
2. Turn off automatic updates **before the first launch**. Smux's update feed still points at official cmux, so an update would replace Smux with stock cmux:
   ```bash
   defaults write com.cmuxterm.app.debug.smux SUEnableAutomaticChecks -bool false
   defaults write com.cmuxterm.app.debug.smux SUAutomaticallyUpdate -bool false
   ```
3. Allow the app to open. Pick one:
   - Open Smux once, then go to **System Settings → Privacy & Security → Open Anyway**.
   - Or remove the download quarantine flag (only for a build you made yourself):
     ```bash
     xattr -dr com.apple.quarantine /Applications/Smux.app
     ```
4. Restore your config (next section). Without it Smux looks like stock cmux.

The VPN tunnel (`cmuxTunnel` system extension) needs a Developer ID–signed build and won't load in a self-signed one.

## Smux config (themes, shader, settings)

Your theme, the `storm.glsl` shader and cmux settings live in your home folder, not inside the app. A copy is kept in [`smux-config/`](smux-config), laid out the same way it sits under `~`:

| In the repo | On the Mac | What it holds |
|---|---|---|
| `smux-config/.config/ghostty/` | `~/.config/ghostty/` | Terminal config, `themes/`, `shaders/` (incl. `storm.glsl`), `backgrounds/` |
| `smux-config/.config/cmux/` | `~/.config/cmux/` | `cmux.json`, `sidebars/` |
| `smux-config/Library/Application Support/com.cmuxterm.app.debug.smux/config.ghostty` | `~/Library/Application Support/com.cmuxterm.app.debug.smux/config.ghostty` | Smux-only settings |

`smux-config/` never contains secrets or lock files. `.gitignore` excludes `*secret*`, `*.lock` and `*.bak*` there. Keep it that way, because `~/.config/cmux/.surface-resume-approval-secret` is per-machine and must not be copied or committed.

All commands below run from the repo root. They only copy files: nothing is deleted, and the restore makes a backup first.

### Restore the config onto a Mac

1. **Quit Smux** (⌘Q).
2. **Back up whatever config this Mac already has:**
   ```bash
   BACKUP="$HOME/smux-config-backup-$(date +%Y%m%d-%H%M%S)"
   mkdir -p "$BACKUP"
   for p in .config/ghostty .config/cmux "Library/Application Support/com.cmuxterm.app.debug.smux/config.ghostty"; do
     if [ -e "$HOME/$p" ]; then
       mkdir -p "$BACKUP/$(dirname "$p")" && cp -Rp "$HOME/$p" "$BACKUP/$p"
     fi
   done
   echo "Backup saved to $BACKUP"
   ```
3. **Copy the repo's config into place:**
   ```bash
   mkdir -p ~/.config/ghostty ~/.config/cmux "$HOME/Library/Application Support/com.cmuxterm.app.debug.smux"
   cp -Rp smux-config/.config/ghostty/. ~/.config/ghostty/
   cp -Rp smux-config/.config/cmux/. ~/.config/cmux/
   cp -p "smux-config/Library/Application Support/com.cmuxterm.app.debug.smux/config.ghostty" \
         "$HOME/Library/Application Support/com.cmuxterm.app.debug.smux/"
   ```
   This adds files and overwrites ones with the same name. Files that exist only on the Mac are left alone.
4. **Check it:**
   ```bash
   ls ~/.config/ghostty/config ~/.config/ghostty/shaders/storm.glsl ~/.config/cmux/cmux.json \
      "$HOME/Library/Application Support/com.cmuxterm.app.debug.smux/config.ghostty"
   ```
   All four paths should print with no "No such file" errors. Then open Smux.

**To undo**, quit Smux and copy the backup back:
```bash
cp -Rp "$BACKUP"/. ~/
```
If you're in a new Terminal window, set `BACKUP` to the folder name printed in step 2 first.

### Save config changes back to the repo

After changing your theme, shader or settings on your main Mac:

```bash
cp -Rp ~/.config/ghostty/. smux-config/.config/ghostty/
cp -Rp ~/.config/cmux/. smux-config/.config/cmux/
cp -p "$HOME/Library/Application Support/com.cmuxterm.app.debug.smux/config.ghostty" \
      "smux-config/Library/Application Support/com.cmuxterm.app.debug.smux/"

git status -- smux-config        # review what changed
git diff -- smux-config          # check for anything private before committing
git add smux-config
git commit -m "Update Smux config"
```

The `.gitignore` rules keep the secret and lock files out when you run `git add`. A file you delete locally isn't removed from `smux-config/`; remove it there by hand.

## Other Smux data

Sessions, history and caches aren't in the repo:

- `~/Library/Application Support/cmux/*smux*`
- `~/Library/Application Support/com.cmuxterm.app.debug.smux/`

## License

Smux inherits the license of cmux. See [`LICENSE`](LICENSE) and [`README.cmux.md`](README.cmux.md).
