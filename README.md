# craft-mirror

Downloads installers from GitHub releases (ArtCraft, and any app the ArtCraft
Launcher offers, such as MailCraft) into a folder. It keeps the newest N versions
per project and lets you pin versions so they're kept forever.

## Install (Linux)

You need `bash`, `curl` and `jq`:

```sh
sudo apt install curl jq        # Debian/Ubuntu
sudo dnf install curl jq        # Fedora/RHEL
```

You choose both folders:

- **Script folder:** where the script and its config live. It can be anywhere,
  because the script looks for `craft-mirror.conf` next to itself.
- **`DEST_DIR`:** where the installers are stored. Set it in the config.

### Option 1: download the files directly

```sh
INSTALL_DIR=/path/of/your/choice          # e.g. ~/craft-mirror or /srv/craft-mirror
mkdir -p "$INSTALL_DIR" && cd "$INSTALL_DIR"
BASE=https://raw.githubusercontent.com/rolfedguynl/craft-mirror/main
curl -fsSLO "$BASE/craft-mirror.sh"
curl -fsSLO "$BASE/craft-mirror.conf.example"
cp craft-mirror.conf.example craft-mirror.conf
chmod 755 craft-mirror.sh && chmod 600 craft-mirror.conf
editor craft-mirror.conf                  # set DEST_DIR, projects, platforms, KEEP
```

To update later, download `craft-mirror.sh` again. Your `craft-mirror.conf` isn't
touched.

### Option 2: clone the repo (easy updates with `git pull`)

```sh
git clone https://github.com/rolfedguynl/craft-mirror.git /path/of/your/choice
cd /path/of/your/choice
cp craft-mirror.conf.example craft-mirror.conf
chmod 600 craft-mirror.conf
editor craft-mirror.conf
```

Your `craft-mirror.conf` is in `.gitignore`, so `git pull` never overwrites it,
and it can't be committed by accident. That matters because it may hold a
`GITHUB_TOKEN`.

### Try it

```sh
./craft-mirror.sh -n          # dry run: shows what it would download
./craft-mirror.sh             # the real thing
```

You can also change the storage folder for a single run: `-d /other/folder` or
`CRAFT_MIRROR_DEST=/other/folder`. Use `-c /path/to/file.conf` to load a config
from somewhere else.

## Manual use

```sh
./craft-mirror.sh -n                  # dry run: show what would happen
./craft-mirror.sh                     # mirror all configured projects
./craft-mirror.sh run artcraft        # only one project
./craft-mirror.sh list                # stored versions, * = pinned
./craft-mirror.sh catalog             # apps the launcher offers, + = selected
./craft-mirror.sh pin artcraft artcraft-v0.37.0    # keep forever (downloads if missing)
./craft-mirror.sh unpin artcraft artcraft-v0.37.0
```

## Platforms

`PLATFORMS="windows linux"` picks which platforms to download. Out of the box it
downloads:

- **Windows:** the x64 `.exe` / `.msi` installers.
- **Linux:** the x86_64 **AppImage**, the most versatile format. It's a single
  file that runs on any distro without installing or root. If you also want
  `.deb`/`.rpm`, change `PATTERN_linux` (the config shows how).
- **macOS:** the `.dmg`, if you add `macos` to `PLATFORMS`.

## Launcher apps (office suite, MailCraft, ...)

The ArtCraft Launcher's catalog (`https://getartcraft.com/launcher-catalog.toml`)
lists the `official` apps and the `community` apps it supports, such as MailCraft.
The example config mirrors the office suite:

```sh
CATALOG_KINDS="official community"     # MailCraft is "community", the rest "official"
CATALOG_INCLUDE="pdfcraft wordcraft deckcraft gridcraft mailcraft"
```

- Leave `CATALOG_INCLUDE` empty to get every app of those kinds.
- `CATALOG_EXCLUDE` skips apps.
- `./craft-mirror.sh catalog` shows every app ever seen in the catalog, with `+`
  next to the selected ones.
- The script doesn't check the catalog's signature. It only uses the catalog to
  find each app's GitHub repo.

### Saved catalog (works without the launcher)

Every run saves the catalog to `CATALOG_DIR` (default `$DEST_DIR/launcher-catalog`):

```
launcher-catalog/
  launcher-catalog.toml      latest copy (+ .sig when the site serves one)
  known-apps.tsv             every app ever seen: id, repo, kind, first/last seen, still listed?
  archive/
    launcher-catalog-20261125T031500Z-<hash>.toml   each distinct version, never deleted
```

So apps keep updating straight from their GitHub repos when the launcher isn't
available:

- **Launcher site down:** the script tries the next source in `CATALOG_URLS` (the
  launcher's GitHub repo). If none of them work, it uses the saved
  `known-apps.tsv`.
- **App removed from the catalog** (technically or legally): the app stays in
  `known-apps.tsv`, marked as removed, and is still mirrored from its repo. Set
  `CATALOG_KEEP_REMOVED=false` to stop instead.
- **Catalog taken down or emptied:** an empty or invalid download never replaces
  the saved copy, and old versions stay in `archive/`.
- **App's GitHub repo gone:** nothing is deleted. Pruning only happens after a
  successful check, so the versions you already have stay.

Each app costs one GitHub API call per run. Without a token, GitHub allows 60
calls per hour, which is plenty for a daily cron. If you run it more often, set
`GITHUB_TOKEN`.

## Pinning

Pinning just creates a `.keep` file in the version folder, so
`touch "$DEST_DIR/artcraft/artcraft-v0.41.1/.keep"` works too.
Pinned versions don't count toward `KEEP`.

## Cron

```cron
# daily at 03:15 (use your own paths)
15 3 * * * /path/of/your/choice/craft-mirror.sh >> /path/to/craft-mirror.log 2>&1
```

The script exits non-zero when a project fails, uses `flock` so runs never overlap,
and resumes interrupted downloads on the next run (a version only counts as present
once its `.complete` marker exists).

## Folder layout

```
$DEST_DIR/
  launcher-catalog/    <- saved catalog, see above
  artcraft/
    artcraft-v0.41.1/
      ArtCraft_0.41.1_x64-setup.exe
      ArtCraft_0.41.1_x64_en-US.msi
      artcraft-0.41.1-linux-x86_64.AppImage
      SHA256SUMS.txt
      .complete
    artcraft-v0.37.0/
      ...
      .keep            <- pinned
  wordcraft/
  pdfcraft/
  deckcraft/
  gridcraft/
  mailcraft/
```
