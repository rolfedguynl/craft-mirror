#!/usr/bin/env bash
# craft-mirror.sh - mirror installers from GitHub releases into a local folder,
# keeping the newest N versions per project. Versions containing a `.keep` file
# SPDX-License-Identifier: MIT OR Apache-2.0
# are never pruned.
#
# Layout:  $DEST_DIR/<project>/<tag>/<installer files>
#          $DEST_DIR/<project>/<tag>/.complete   (written after a successful download)
#          $DEST_DIR/<project>/<tag>/.keep       (pin: never delete this version)
#
# Requires: bash 4+, curl, jq. Optional: flock, sha256sum.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${CRAFT_MIRROR_CONFIG:-$SCRIPT_DIR/craft-mirror.conf}"
DRY_RUN=0
DEST_OVERRIDE="${CRAFT_MIRROR_DEST:-}"

# ---------------------------------------------------------------- defaults
# Everything below can be overridden in the config file.
DEST_DIR="/srv/installers"
KEEP=5                     # unpinned versions to keep per project (0 = keep all)
FETCH_COUNT=1              # how many of the newest releases to make sure are present
PLATFORMS="windows linux"  # which PATTERN_<platform> entries to download
INCLUDE_PRERELEASE=false
VERIFY_SHA256=true         # verify against a downloaded SHA256SUMS file, if any
GITHUB_TOKEN=""            # optional; raises API rate limit, needed for private repos
LOCK_FILE="/tmp/craft-mirror.lock"

# Asset-name regexes. "[0-9]" up front = only versioned files (some apps also
# publish unversioned duplicates).
PATTERN_windows='[0-9][^/]*[_-]x64([_-][^/]*)?\.(exe|msi)$'
PATTERN_linux='[0-9][^/]*-linux-x86_64\.AppImage$'   # AppImage: runs on any distro
PATTERN_macos='[0-9][^/]*\.dmg$'
EXTRA_PATTERN='^SHA256SUMS(\.txt)?$'   # always downloaded alongside ("" to disable)

PROJECTS=()

# Apps listed in the ArtCraft Launcher catalog.
# Sources tried in order; the first one that returns a valid catalog is used.
CATALOG_URLS="https://getartcraft.com/launcher-catalog.toml
              https://raw.githubusercontent.com/storytold/craft-launcher/HEAD/crates/core/catalog.toml"
CATALOG_KINDS=""        # "" = off; "official", "community" or "official community"
CATALOG_INCLUDE=""      # if set: only these app ids from the catalog
CATALOG_EXCLUDE=""      # app ids to skip
CATALOG_DIR=""          # where the catalog is saved ("" = $DEST_DIR/launcher-catalog)
CATALOG_SAVE=true       # save/archive the catalog on every run, even if CATALOG_KINDS=""
CATALOG_KEEP_REMOVED=true  # keep mirroring apps that disappear from the catalog

# ---------------------------------------------------------------- helpers
# All log output goes to stderr, so stdout stays clean for list/catalog output.
log()  { printf '%s [INFO]  %s\n' "$(date '+%F %T')" "$*" >&2; }
warn() { printf '%s [WARN]  %s\n' "$(date '+%F %T')" "$*" >&2; }
err()  { printf '%s [ERROR] %s\n' "$(date '+%F %T')" "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [-c CONFIG] [-n] [command] [args]

Commands:
  run [project...]           Download new releases and prune old ones (default).
                             Without project names: PROJECTS from the config plus
                             the launcher-catalog apps selected by CATALOG_KINDS.
  list [project...]          Show stored versions (* = pinned).
  catalog                    Update the saved catalog and show every app ever seen
                             in it (+ = selected, REMOVED = dropped from catalog).
  pin <project> <tag>        Keep this version forever (downloads it if missing).
  unpin <project> <tag>      Remove the pin; the version is pruned normally again.

Options:
  -c CONFIG   Config file (default: $CONFIG, or \$CRAFT_MIRROR_CONFIG)
  -d DIR      Store installers in DIR, overriding DEST_DIR (or \$CRAFT_MIRROR_DEST)
  -n         Dry run: show what would be downloaded/deleted, change nothing.
  -h          Help.
EOF
}

# Per-project setting with fallback: pvar <project> <KEY> <default>
# Reads <project>_<KEY> from the config (non-alphanumerics in the name become _).
pvar() {
  local name="${1//[^a-zA-Z0-9_]/_}_$2"
  printf '%s' "${!name:-$3}"
}

safe_name() { local s="${1//\//_}"; [[ $s == .* ]] && s="_$s"; printf '%s' "$s"; }

curl_auth() {
  local -n _arr=$1
  if [[ -n $GITHUB_TOKEN ]]; then _arr+=(-H "Authorization: Bearer $GITHUB_TOKEN"); fi
}

api() {
  local args=(-fsSL --retry 3 --retry-delay 5
              -H "Accept: application/vnd.github+json"
              -H "X-GitHub-Api-Version: 2022-11-28")
  curl_auth args
  curl "${args[@]}" "https://api.github.com/$1"
}

download() { # <asset api url> <output file>
  local args=(-fsSL --retry 3 --retry-delay 5 -H "Accept: application/octet-stream" -o "$2")
  curl_auth args
  curl "${args[@]}" "$1"
}

# Build the combined asset-name regex for a project from its platforms.
asset_regex() {
  local p="$1" regex="" plat pat g extra
  for plat in $(pvar "$p" PLATFORMS "$PLATFORMS"); do
    pat=$(pvar "$p" "PATTERN_$plat" "")
    if [[ -z $pat ]]; then g="PATTERN_$plat"; pat="${!g:-}"; fi
    [[ -n $pat ]] || { err "$p: no PATTERN_$plat defined"; return 1; }
    regex+="${regex:+|}($pat)"
  done
  extra=$(pvar "$p" EXTRA_PATTERN "$EXTRA_PATTERN")
  [[ -n $extra && -n $regex ]] && regex+="|($extra)"
  [[ -n $regex ]] || { err "$p: no platforms selected"; return 1; }
  printf '%s' "$regex"
}

in_list() { local x; for x in $2; do [[ $x == "$1" ]] && return 0; done; return 1; }

# ---------------------------------------------------------------- catalog
# The catalog is saved so the mirror keeps working when the launcher's catalog
# is unreachable, taken down, or drops apps:
#
#   $CATALOG_DIR/launcher-catalog.toml(.sig)  latest copy that was downloaded
#   $CATALOG_DIR/archive/launcher-catalog-<UTC time>-<hash>.toml(.sig)
#                                             every distinct version ever seen (never pruned)
#   $CATALOG_DIR/known-apps.tsv               every app ever seen: id, repo, kind,
#                                             first seen, last seen, still in catalog?
#
# Apps are resolved from known-apps.tsv, so an app removed from the catalog
# (or a catalog that can't be reached at all) is still updated straight from
# its GitHub repo.

catalog_dir() {
  local d="${CATALOG_DIR:-$DEST_DIR/launcher-catalog}"
  [[ $d == /* ]] || d="$SCRIPT_DIR/$d"
  printf '%s' "$d"
}

# parse_catalog <file>: prints "id<TAB>repo<TAB>kind" for every app.
parse_catalog() {
  awk '
    { sub(/\r$/, "") }
    function flush() { if (id != "" && repo != "") print id "\t" repo "\t" kind; id = repo = kind = "" }
    /^\[\[apps\]\]/ { flush(); inapp = 1; next }
    /^\[/           { inapp = 0; next }          # [apps.details] etc.
    inapp && /^(id|repo|kind)[ \t]*=/ {
      key = $0; sub(/[ \t]*=.*/, "", key)
      val = $0; sub(/^[^=]*=[ \t]*"/, "", val); sub(/".*$/, "", val)
      if (key == "id") id = val; else if (key == "repo") repo = val; else kind = val
    }
    END { flush() }' "$1" |
  grep -E $'^[a-z0-9][a-z0-9_-]*\t[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\t' || true
}

# merge_known <known-apps.tsv> <current apps>: prints the updated registry.
# Apps no longer in the catalog stay in it, marked in_catalog=no.
merge_known() {
  local known="$1" apps="$2"
  [[ -f $known ]] || known=/dev/null
  printf '#id\trepo\tkind\tfirst_seen\tlast_seen\tin_catalog\n'
  awk -F'\t' -v OFS='\t' -v today="$(date -u +%F)" '
    FNR == NR { cur[$1] = $2 OFS $3; order[++n] = $1; next }   # current catalog
    /^#/ || NF < 6 { next }
    { old[$1] = $0; first[$1] = $4; oorder[++m] = $1 }         # saved registry
    END {
      for (i = 1; i <= n; i++) { id = order[i]
        print id, cur[id], (id in first ? first[id] : today), today, "yes" }
      for (i = 1; i <= m; i++) { id = oorder[i]
        if (id in cur) continue
        split(old[id], f, "\t"); print f[1], f[2], f[3], f[4], f[5], "no" }
    }' <(printf '%s\n' "$apps") "$known"
}

# update_catalog: download + archive the catalog, update the registry, and
# print the registry. Falls back to the saved registry if no source works.
update_catalog() {
  local dir known tmp url got="" apps hash merged
  dir=$(catalog_dir); known="$dir/known-apps.tsv"
  tmp=$(mktemp)
  for url in $CATALOG_URLS; do
    if curl -fsSL --retry 2 --retry-delay 5 -o "$tmp" "$url" && grep -q '^\[\[apps\]\]' "$tmp"; then
      got=$url; break
    fi
    warn "launcher catalog not available from $url"
  done
  [[ -n $got ]] && apps=$(parse_catalog "$tmp") || apps=""

  if [[ -z $apps ]]; then
    rm -f "$tmp"
    [[ -f $known ]] || { err "launcher catalog unavailable and no saved copy in $dir"; return 1; }
    warn "using the saved launcher catalog ($known)"
    cat "$known"
    return 0
  fi

  merged=$(merge_known "$known" "$apps")
  if (( ! DRY_RUN )); then
    mkdir -p "$dir/archive"
    hash=$( (sha256sum "$tmp" 2>/dev/null || cksum "$tmp") | cut -d' ' -f1 | cut -c1-16)
    if ! compgen -G "$dir/archive/launcher-catalog-*-$hash.toml" >/dev/null; then
      local base="$dir/archive/launcher-catalog-$(date -u +%Y%m%dT%H%M%SZ)-$hash.toml"
      cp "$tmp" "$base"
      curl -fsSL -o "$base.sig" "$got.sig" 2>/dev/null || rm -f "$base.sig"
      [[ -f $base.sig ]] && cp "$base.sig" "$dir/launcher-catalog.toml.sig"
      log "saved new launcher catalog version: $(basename "$base") (from $got)"
    fi
    mv -f "$tmp" "$dir/launcher-catalog.toml"
    printf '%s\n' "$merged" > "$known.tmp" && mv -f "$known.tmp" "$known"
  else
    rm -f "$tmp"
  fi
  printf '%s\n' "$merged"
}

catalog_selected() { # <id> <kind> <in_catalog yes|no>
  in_list "$2" "$CATALOG_KINDS" || return 1
  [[ -z $CATALOG_INCLUDE ]] || in_list "$1" "$CATALOG_INCLUDE" || return 1
  in_list "$1" "$CATALOG_EXCLUDE" && return 1
  [[ $3 == yes || $CATALOG_KEEP_REMOVED == true ]] || return 1
  return 0
}

# Fills ALL_PROJECTS = PROJECTS + selected catalog apps, and sets <id>_REPO for
# catalog apps (unless the config already sets it).
ALL_PROJECTS=()
resolve_projects() {
  local id repo kind first last incat var p registry
  ALL_PROJECTS=("${PROJECTS[@]}")
  [[ -n $CATALOG_KINDS || $CATALOG_SAVE == true ]] || return 0
  [[ -n ${CATALOG_URLS// /} ]] || return 0
  registry=$(update_catalog) || return 1
  while IFS=$'\t' read -r id repo kind first last incat; do
    [[ -n $id && $id != \#* ]] || continue
    var="${id//[^a-zA-Z0-9_]/_}_REPO"
    [[ -n ${!var:-} ]] || printf -v "$var" '%s' "$repo"
    if catalog_selected "$id" "$kind" "$incat"; then
      [[ $incat == yes ]] || warn "$id is no longer in the launcher catalog (last seen $last); still mirroring $repo"
      for p in "${ALL_PROJECTS[@]}"; do [[ $p == "$id" ]] && continue 2; done
      ALL_PROJECTS+=("$id")
    fi
  done <<<"$registry"
}

cmd_catalog() {
  local id repo kind first last incat mark status
  printf '  %-16s %-10s %-28s %s\n' ID KIND REPO STATUS
  while IFS=$'\t' read -r id repo kind first last incat; do
    [[ -n $id && $id != \#* ]] || continue
    mark=" "; catalog_selected "$id" "$kind" "$incat" && mark="+"
    if [[ $incat == yes ]]; then status="in catalog since $first"
    else status="REMOVED from catalog, last seen $last"; fi
    printf '%s %-16s %-10s %-28s %s\n' "$mark" "$id" "$kind" "$repo" "$status"
  done < <(update_catalog)
  echo "Saved in: $(catalog_dir)"
}

# ---------------------------------------------------------------- core
# download_release <project> <releases-json-array> <tag> <published> <regex>
download_release() {
  local p="$1" releases="$2" tag="$3" published="$4" regex="$5"
  local vdir="$DEST_DIR/$p/$(safe_name "$tag")"

  if [[ -f $vdir/.complete ]]; then
    log "$p $tag: already present"
    return 0
  fi

  local assets
  assets=$(jq -r --arg t "$tag" --arg re "$regex" '
      .[] | select(.tag_name == $t) | .assets[]
          | select(.name | test($re)) | [.name, .url, (.size|tostring)] | @tsv' <<<"$releases")
  if [[ -z $assets ]]; then
    warn "$p $tag: no assets match the configured platforms"
    return 0
  fi

  if (( DRY_RUN )); then
    log "$p $tag: would download:"; cut -f1 <<<"$assets" | sed 's/^/    /'
    return 0
  fi

  mkdir -p "$vdir"
  local name url size
  while IFS=$'\t' read -r name url size; do
    name=$(safe_name "$name")
    if [[ -f $vdir/$name && $(stat -c %s "$vdir/$name") == "$size" ]]; then
      continue   # already fetched by an earlier, interrupted run
    fi
    log "$p $tag: downloading $name ($(numfmt --to=iec "$size" 2>/dev/null || echo "$size B"))"
    if ! download "$url" "$vdir/$name.part"; then
      rm -f "$vdir/$name.part"
      err "$p $tag: download of $name failed"
      return 1
    fi
    mv -f "$vdir/$name.part" "$vdir/$name"
  done <<<"$assets"

  if [[ $(pvar "$p" VERIFY_SHA256 "$VERIFY_SHA256") == true ]] && command -v sha256sum >/dev/null; then
    local sums
    sums=$(find "$vdir" -maxdepth 1 -type f -iname 'SHA256SUMS*' ! -name '*.part' | head -n1)
    if [[ -n $sums ]]; then
      if ! (cd "$vdir" && sha256sum -c --ignore-missing --quiet "$(basename "$sums")"); then
        err "$p $tag: checksum verification failed, removing download"
        rm -rf -- "$vdir"
        return 1
      fi
      log "$p $tag: checksums OK"
    fi
  fi

  printf 'tag=%s\npublished=%s\nrepo=%s\ndownloaded=%s\n' \
    "$tag" "$published" "$(pvar "$p" REPO "")" "$(date -u '+%FT%TZ')" > "$vdir/.complete"
  log "$p $tag: done"
}

prune_project() {
  local p="$1" dir="$DEST_DIR/$1" keep n=0 published vdir
  keep=$(pvar "$p" KEEP "$KEEP")
  (( keep > 0 )) || return 0
  [[ -d $dir ]] || return 0

  while IFS=$'\t' read -r published vdir; do
    [[ -f $vdir/.keep ]] && continue
    n=$((n + 1))
    if (( n > keep )); then
      if (( DRY_RUN )); then log "$p: would delete $(basename "$vdir")"
      else log "$p: deleting $(basename "$vdir")"; rm -rf -- "$vdir"; fi
    fi
  done < <(
    for f in "$dir"/*/.complete; do
      [[ -f $f ]] || continue
      printf '%s\t%s\n' "$(sed -n 's/^published=//p' "$f")" "$(dirname "$f")"
    done | sort -r
  )
}

mirror_project() {
  local p="$1" repo fetch pre regex releases rc=0 tag published
  repo=$(pvar "$p" REPO "")
  [[ -n $repo ]] || { err "$p: ${p//[^a-zA-Z0-9_]/_}_REPO is not set"; return 1; }
  fetch=$(pvar "$p" FETCH_COUNT "$FETCH_COUNT")
  pre=$(pvar "$p" INCLUDE_PRERELEASE "$INCLUDE_PRERELEASE")
  regex=$(asset_regex "$p") || return 1

  releases=$(api "repos/$repo/releases?per_page=30") || { err "$p: GitHub API request failed"; return 1; }

  while IFS=$'\t' read -r tag published; do
    download_release "$p" "$releases" "$tag" "$published" "$regex" || rc=1
  done < <(jq -r --argjson pre "$pre" --argjson n "$fetch" '
      [ .[] | select(.draft | not) | select($pre or (.prerelease | not)) ]
      | sort_by(.published_at) | reverse | .[:$n][]
      | [.tag_name, .published_at] | @tsv' <<<"$releases")

  prune_project "$p"
  return $rc
}

# ---------------------------------------------------------------- commands
cmd_run() {
  local projects=("$@") rc=0 p
  resolve_projects || rc=1
  (( ${#projects[@]} )) || projects=("${ALL_PROJECTS[@]}")
  (( ${#projects[@]} )) || die "no projects configured (PROJECTS / CATALOG_KINDS in $CONFIG)"
  for p in "${projects[@]}"; do
    log "== $p"
    mirror_project "$p" || rc=1
  done
  return $rc
}

cmd_list() {
  local projects=("$@") p f vdir mark
  if (( ! ${#projects[@]} )); then   # every project folder on disk
    for p in "$DEST_DIR"/*/; do
      [[ -d $p && ${p%/} != "$(catalog_dir)" ]] && projects+=("$(basename "$p")")
    done
  fi
  for p in "${projects[@]}"; do
    echo "$p:"
    for f in "$DEST_DIR/$p"/*/.complete; do
      [[ -f $f ]] || continue
      vdir=$(dirname "$f")
      mark=" "; [[ -f $vdir/.keep ]] && mark="*"
      printf '  %-22s %s %-30s %s\n' "$(sed -n 's/^published=//p' "$f")" \
        "$mark" "$(basename "$vdir")" "$(du -sh "$vdir" | cut -f1)"
    done | sort -r
  done
}

cmd_pin() {
  local p="${1:-}" tag="${2:-}" repo regex rel published vdir
  [[ -n $p && -n $tag ]] || die "usage: pin <project> <tag>"
  vdir="$DEST_DIR/$p/$(safe_name "$tag")"
  if [[ ! -f $vdir/.complete ]]; then
    resolve_projects || true
    repo=$(pvar "$p" REPO "")
    [[ -n $repo ]] || die "$p: REPO is not set"
    regex=$(asset_regex "$p") || exit 1
    rel=$(api "repos/$repo/releases/tags/$tag" | jq '[.]') || die "$p: release $tag not found"
    published=$(jq -r '.[0].published_at' <<<"$rel")
    download_release "$p" "$rel" "$tag" "$published" "$regex" || exit 1
  fi
  if (( DRY_RUN )); then log "$p $tag: would pin"; return; fi
  printf 'pinned=%s\n' "$(date -u '+%FT%TZ')" > "$vdir/.keep"
  log "$p $tag: pinned (will never be pruned)"
}

cmd_unpin() {
  local p="${1:-}" tag="${2:-}" vdir
  [[ -n $p && -n $tag ]] || die "usage: unpin <project> <tag>"
  vdir="$DEST_DIR/$p/$(safe_name "$tag")"
  [[ -f $vdir/.keep ]] || die "$p $tag is not pinned"
  rm -f "$vdir/.keep"
  log "$p $tag: unpinned (pruned on next run if older than the newest $(pvar "$p" KEEP "$KEEP"))"
}

# ---------------------------------------------------------------- main
while getopts ":c:d:nh" opt; do
  case $opt in
    c) CONFIG=$OPTARG ;;
    d) DEST_OVERRIDE=$OPTARG ;;
    n) DRY_RUN=1 ;;
    h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))

[[ -f $CONFIG ]] || die "config not found: $CONFIG"
# shellcheck source=/dev/null
source "$CONFIG"
[[ -n $DEST_OVERRIDE ]] && DEST_DIR=$DEST_OVERRIDE
[[ $DEST_DIR == /* ]] || DEST_DIR="$SCRIPT_DIR/$DEST_DIR"   # relative = next to the script

for dep in curl jq; do command -v "$dep" >/dev/null || die "missing dependency: $dep"; done

cmd="${1:-run}"; shift || true

case $cmd in
  run|pin|unpin|catalog)
    if command -v flock >/dev/null && (( ! DRY_RUN )); then
      exec 9>"$LOCK_FILE"
      flock -n 9 || { log "another run is in progress, exiting"; exit 0; }
    fi
    mkdir -p "$DEST_DIR"
    "cmd_$cmd" "$@"
    ;;
  list) cmd_list "$@" ;;
  help) usage ;;
  *) usage >&2; exit 2 ;;
esac
