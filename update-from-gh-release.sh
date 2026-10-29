#!/usr/bin/env bash
# update-from-gh-release: update an app from its latest GitHub release (Steam Deck / SteamOS friendly).
# Keep this file and its configs OUTSIDE the folders they update (e.g. ~/bin/).
#
#   Update now (own non-Steam shortcut, or Konsole; also does a first install):
#     /home/deck/bin/update-from-gh-release.sh /home/deck/bin/myapp.conf
#   As a game's Steam launch options (asks, auto-plays after ASK_TIMEOUT s):
#     /home/deck/bin/update-from-gh-release.sh /home/deck/bin/myapp.conf --ask %command%
#
# See examples/speedbreaker.conf for a sample config.
set -uo pipefail

CONF="${1:-}"; shift || true
ASK=0; GAME=()
if [ "${1:-}" = "--ask" ]; then ASK=1; GAME=("${@:2}"); fi
tmp=""

# Always end by starting the game (if we were given %command%), whatever happened.
finish() {
  [ -n "$tmp" ] && rm -rf "$tmp"
  [ ${#GAME[@]} -gt 0 ] && exec "${GAME[@]}"
  exit "${1:-0}"
}
have_zenity() { command -v zenity >/dev/null 2>&1; }
msg() {  # msg info|error "text" -- always times out, so it never needs input
  local kind=$1; shift
  if have_zenity; then
    zenity --"$kind" --width=420 --title="${APP_NAME:-Updater}" \
      --timeout="${ASK_TIMEOUT:-10}" --text="$*" 2>/dev/null
  else
    printf '%b\n' "$*" >&2
  fi
  return 0
}
fail() { msg error "${APP_NAME:-App} update failed:\n$*"; finish 1; }

# ---- config ------------------------------------------------------------------
[ -f "$CONF" ] || fail "Usage: update-from-gh-release.sh <config file> [--ask %command%]"
# Defaults (override in the config file)
APP_NAME=""; REPO=""; ASSET_PATTERN=""; INSTALL_DIR=""
CHECKSUM_PATTERN=""         # regex for a .sha256 / SHA256SUMS asset; empty = skip check
REQUIRED_FILE=""            # file that must exist in the new version, e.g. launcher
RUNNING_MATCH=""            # pgrep -f pattern; refuse to update while it matches
STRIP_TOP_DIR=auto          # auto: drop the archive's single top-level folder; 0: keep
RAW_NAME=""                 # non-archive assets (AppImage...): name to install it as
INCLUDE_PRERELEASES=0
CHECK_EVERY=$((24 * 3600))  # --ask mode: check GitHub at most this often (seconds)
ASK_TIMEOUT=10
NET_TIMEOUT_ASK=3
# shellcheck source=/dev/null
. "$CONF"
for v in APP_NAME REPO ASSET_PATTERN INSTALL_DIR; do
  [ -n "${!v}" ] || fail "$v is not set in $CONF"
done
STAMP="$INSTALL_DIR/.update-from-gh-release-version"
CACHE_DIR="$HOME/.cache/update-from-gh-release/${REPO//\//_}"

# ---- checks ------------------------------------------------------------------
if [ $ASK = 0 ] && [ -n "$RUNNING_MATCH" ] && pgrep -f "$RUNNING_MATCH" >/dev/null; then
  fail "$APP_NAME is running. Quit it first."
fi

# --ask mode: skip the check if we already checked recently (keeps launches instant).
if [ $ASK = 1 ]; then
  mkdir -p "$CACHE_DIR"
  last=$(cat "$CACHE_DIR/last-check" 2>/dev/null || echo 0)
  [ $(( $(date +%s) - last )) -lt "$CHECK_EVERY" ] && finish 0
fi

# ---- ask GitHub --------------------------------------------------------------
api="https://api.github.com/repos/$REPO/releases/latest"
[ "$INCLUDE_PRERELEASES" = 1 ] && api="https://api.github.com/repos/$REPO/releases?per_page=1"
net_timeout=15; [ $ASK = 1 ] && net_timeout=$NET_TIMEOUT_ASK
auth=(); [ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")

json=$(curl -fsSL --max-time "$net_timeout" "${auth[@]}" "$api")
if [ -z "$json" ]; then
  [ $ASK = 1 ] && finish 0          # offline/slow: just play
  fail "Couldn't reach GitHub."
fi
[ $ASK = 1 ] && date +%s > "$CACHE_DIR/last-check"

# Prints: tag, asset name, asset url, checksum url ("-" if none). Errors go to stderr.
mapfile -t rel < <(printf '%s' "$json" | python3 -c '
import json, re, sys
d = json.load(sys.stdin)
if isinstance(d, list):
    d = d[0] if d else {}
assets = d.get("assets", [])
def find(p):
    m = [a for a in assets if p and re.search(p, a["name"])]
    return m
a = find(sys.argv[1])
if not d.get("tag_name") or len(a) != 1:
    sys.exit("no release" if not d.get("tag_name") else
             f"ASSET_PATTERN matched {len(a)} assets: " + ", ".join(x["name"] for x in a))
c = find(sys.argv[2])
print(d["tag_name"]); print(a[0]["name"]); print(a[0]["browser_download_url"])
print(c[0]["browser_download_url"] if c else "-")
' "$ASSET_PATTERN" "$CHECKSUM_PATTERN" 2>&1)
[ ${#rel[@]} -eq 4 ] || fail "Couldn't read the release: ${rel[*]}"
latest=${rel[0]}; asset=${rel[1]}; asset_url=${rel[2]}; sum_url=${rel[3]}
[ -n "$CHECKSUM_PATTERN" ] && [ "$sum_url" = "-" ] && fail "No checksum asset matched CHECKSUM_PATTERN."

current=$(cat "$STAMP" 2>/dev/null || echo "unknown")
if [ "$latest" = "$current" ]; then
  [ $ASK = 0 ] && msg info "$APP_NAME is up to date ($current)."
  finish 0
fi

if [ $ASK = 1 ]; then
  have_zenity || finish 0           # can't ask: just play
  zenity --question --width=420 --title="$APP_NAME" \
    --timeout="$ASK_TIMEOUT" --default-cancel \
    --ok-label="Update" --cancel-label="Play now" \
    --text="$APP_NAME $latest is available (you have $current).\n\nStarting in $ASK_TIMEOUT seconds unless you choose Update." \
    2>/dev/null || finish 0         # Play now, timeout or closed: play
fi

# ---- download, verify, install -----------------------------------------------
mkdir -p "$INSTALL_DIR" || fail "Couldn't create $INSTALL_DIR"
# Temp folder next to the install (same disk; /tmp is RAM-backed on SteamOS).
tmp=$(mktemp -d -p "$(dirname "$INSTALL_DIR")" .gh-update.XXXXXX) || fail "Couldn't create a temporary folder."

do_update() {
  err() { echo "$1" > "$tmp/err"; }
  echo "# Downloading $asset..."
  curl -fsSL --retry 3 -o "$tmp/$asset" "$asset_url" || { err "Download failed."; return 1; }
  if [ "$sum_url" != "-" ]; then
    echo "# Verifying..."
    curl -fsSL --retry 3 -o "$tmp/checksums" "$sum_url" || { err "Checksum download failed."; return 1; }
    # Works for single-file .sha256 and multi-file SHA256SUMS lists.
    grep -q "$asset" "$tmp/checksums" || { err "Checksum file doesn't list $asset."; return 1; }
    (cd "$tmp" && sha256sum -c --ignore-missing checksums >/dev/null 2>&1) || { err "Checksum mismatch."; return 1; }
  fi
  echo "# Unpacking..."
  local x="$tmp/x"; mkdir "$x"
  case "$asset" in
    *.tar|*.tar.*|*.tgz|*.tbz2|*.txz)
      tar -xf "$tmp/$asset" -C "$x" || { err "Unpacking failed."; return 1; } ;;
    *.zip)
      if command -v unzip >/dev/null; then unzip -q "$tmp/$asset" -d "$x"
      elif command -v bsdtar >/dev/null; then bsdtar -xf "$tmp/$asset" -C "$x"
      else false; fi || { err "Unpacking failed (needs unzip or bsdtar)."; return 1; } ;;
    *)  # single file (AppImage, binary...)
      cp "$tmp/$asset" "$x/${RAW_NAME:-$asset}" && chmod +x "$x/${RAW_NAME:-$asset}" \
        || { err "Preparing file failed."; return 1; } ;;
  esac
  local src="$x"
  if [ "$STRIP_TOP_DIR" = auto ]; then
    local entries=("$x"/* "$x"/.[!.]*)
    entries=("${entries[@]}"); local real=()
    for e in "${entries[@]}"; do [ -e "$e" ] && real+=("$e"); done
    [ ${#real[@]} -eq 1 ] && [ -d "${real[0]}" ] && src="${real[0]}"
  fi
  if [ -n "$REQUIRED_FILE" ] && [ ! -e "$src/$REQUIRED_FILE" ]; then
    err "New version has no $REQUIRED_FILE (unexpected layout)."; return 1
  fi
  echo "# Installing..."
  # Copy over the old folder; never deletes anything already there.
  cp -a "$src/." "$INSTALL_DIR/" || { err "Copying files failed."; return 1; }
  echo "$latest" > "$STAMP"
}

if have_zenity; then
  do_update | zenity --progress --pulsate --auto-close --no-cancel --width=420 \
    --title="$APP_NAME" --text="Updating..." 2>/dev/null
  status=${PIPESTATUS[0]}
else
  do_update; status=$?
fi
[ "$status" -eq 0 ] || fail "$(cat "$tmp/err" 2>/dev/null || echo "Unknown error.")"

[ $ASK = 0 ] && msg info "$APP_NAME updated: $current → $latest"
finish 0
