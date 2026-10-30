#!/usr/bin/env bash
# update-from-gh-release: install or update an app from its latest GitHub release.
# Built for Steam Deck / SteamOS. Keep this script and its configs OUTSIDE the
# folders they update (e.g. ~/bin/).
#
#   Update now (Konsole, a non-Steam shortcut, cron; also does a first install):
#     /home/deck/bin/update-from-gh-release.sh /home/deck/bin/myapp.conf
#   As a game's Steam launch options (asks, then always starts the game):
#     /home/deck/bin/update-from-gh-release.sh /home/deck/bin/myapp.conf --ask %command%
#
# See examples/speedbreaker.conf for a sample config.
set -uo pipefail

CONF=${1:-}; shift || true
ASK=0; GAME=()
if [ "${1:-}" = --ask ]; then ASK=1; GAME=("${@:2}"); fi
tmp=""

# ---- helpers -----------------------------------------------------------------
# Every exit goes through here, so --ask mode always starts the game.
finish() {
  [ -n "$tmp" ] && rm -rf "$tmp"
  [ ${#GAME[@]} -gt 0 ] && exec "${GAME[@]}"
  exit "${1:-0}"
}
# Dialogs need zenity and a display (there is none under cron or ssh).
gui() { [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && command -v zenity >/dev/null; }
say() {  # say info|error TEXT -- times out, so it never waits for input
  if gui; then
    zenity --"$1" --width=420 --title="${APP_NAME:-Updater}" --timeout="$ASK_TIMEOUT" --text="$2" 2>/dev/null
  else
    printf '%b\n' "$2" >&2
  fi
  return 0
}
fail() { say error "${APP_NAME:-App} update failed:\n$1"; finish 1; }

# ---- config ------------------------------------------------------------------
APP_NAME=""; REPO=""; ASSET_PATTERN=""; INSTALL_DIR=""
CHECKSUM_PATTERN=""   # regex for a .sha256 / SHA256SUMS asset; empty: no check
REQUIRED_FILE=""      # must exist in the new version (layout check)
RUNNING_MATCH=""      # pgrep -f pattern: don't update while it matches
ASK_TIMEOUT=10        # seconds before a dialog closes on its own
[ -f "$CONF" ] || fail "Usage: update-from-gh-release.sh <config file> [--ask %command%]"
# shellcheck source=/dev/null
. "$CONF"
for v in APP_NAME REPO ASSET_PATTERN INSTALL_DIR; do
  [ -n "${!v}" ] || fail "$v is not set in $CONF"
done
STAMP="$INSTALL_DIR/.update-from-gh-release-version"

if [ $ASK = 0 ] && [ -n "$RUNNING_MATCH" ] && pgrep -f "$RUNNING_MATCH" >/dev/null; then
  fail "$APP_NAME is running. Quit it first."
fi

# ---- latest release ------------------------------------------------------------
# Short timeout in --ask mode: being offline must not hold up the game.
net_timeout=15; [ $ASK = 1 ] && net_timeout=3
auth=(); [ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
if ! json=$(curl -fsSL --max-time "$net_timeout" "${auth[@]}" \
    "https://api.github.com/repos/$REPO/releases/latest" 2>&1); then
  [ $ASK = 1 ] && finish 0
  fail "Couldn't reach GitHub: ${json#curl: }"
fi

# Prints 4 lines: tag, asset name, asset URL, checksum URL ("-" if none).
mapfile -t rel < <(printf '%s' "$json" | python3 -c '
import json, re, sys
release = json.load(sys.stdin)
def matching(pattern):
    return [a for a in release.get("assets", []) if pattern and re.search(pattern, a["name"])]
assets, sums = matching(sys.argv[1]), matching(sys.argv[2])
if len(assets) != 1:
    sys.exit(f"ASSET_PATTERN matched {len(assets)} assets: " + ", ".join(a["name"] for a in assets))
print(release["tag_name"], assets[0]["name"], assets[0]["browser_download_url"],
      sums[0]["browser_download_url"] if sums else "-", sep="\n")
' "$ASSET_PATTERN" "$CHECKSUM_PATTERN" 2>&1)
[ ${#rel[@]} -eq 4 ] || fail "Couldn't read the release: ${rel[*]}"
latest=${rel[0]} asset=${rel[1]} asset_url=${rel[2]} sum_url=${rel[3]}
[ -n "$CHECKSUM_PATTERN" ] && [ "$sum_url" = - ] && fail "No checksum asset matched CHECKSUM_PATTERN."

current=$(cat "$STAMP" 2>/dev/null || echo unknown)
if [ "$latest" = "$current" ]; then
  [ $ASK = 0 ] && say info "$APP_NAME is up to date ($current)."
  finish 0
fi

if [ $ASK = 1 ]; then
  gui || finish 0  # no way to ask: just play
  zenity --question --width=420 --title="$APP_NAME" \
    --timeout="$ASK_TIMEOUT" --default-cancel \
    --ok-label="Update" --cancel-label="Play now" \
    --text="$APP_NAME $latest is available (you have $current).\n\nStarting in $ASK_TIMEOUT seconds unless you choose Update." \
    2>/dev/null || finish 0  # Play now, timeout or closed: play
fi

# ---- download, verify, install -------------------------------------------------
mkdir -p "$INSTALL_DIR" || fail "Couldn't create $INSTALL_DIR"
# Work next to the install: same disk, and /tmp is RAM-backed on SteamOS.
tmp=$(mktemp -d -p "$(dirname "$INSTALL_DIR")" .gh-update.XXXXXX) || fail "Couldn't create a temporary folder."

# Runs in a subshell; "# ..." lines are progress text for zenity.
install_update() (
  die() { echo "$1" > "$tmp/err"; exit 1; }
  echo "# Downloading $asset..."
  curl -fsSL --retry 3 -o "$tmp/$asset" "$asset_url" || die "Download failed."
  if [ "$sum_url" != - ]; then
    echo "# Verifying..."
    curl -fsSL --retry 3 -o "$tmp/checksums" "$sum_url" || die "Checksum download failed."
    # Works for single-file .sha256 and multi-file SHA256SUMS lists.
    grep -qF "$asset" "$tmp/checksums" || die "Checksum file doesn't list $asset."
    (cd "$tmp" && sha256sum -c --ignore-missing --status checksums) || die "Checksum mismatch."
  fi
  echo "# Unpacking..."
  mkdir "$tmp/x"
  case "$asset" in
    *.zip) bsdtar -xf "$tmp/$asset" -C "$tmp/x" 2>/dev/null || unzip -q "$tmp/$asset" -d "$tmp/x" ;;
    *)     tar -xf "$tmp/$asset" -C "$tmp/x" ;;
  esac || die "Unpacking failed."
  # An archive holding one folder: install that folder's contents.
  shopt -s dotglob nullglob
  src="$tmp/x"; top=("$src"/*)
  [ ${#top[@]} -eq 1 ] && [ -d "${top[0]}" ] && src=${top[0]}
  if [ -n "$REQUIRED_FILE" ] && [ ! -e "$src/$REQUIRED_FILE" ]; then
    die "New version has no $REQUIRED_FILE (unexpected layout)."
  fi
  echo "# Installing..."
  # Copies over the old version; files it no longer has are left in place.
  cp -a "$src/." "$INSTALL_DIR/" || die "Copying files failed."
  echo "$latest" > "$STAMP"
)

if gui; then
  install_update | zenity --progress --pulsate --auto-close --no-cancel --width=420 \
    --title="$APP_NAME" --text="Updating..." 2>/dev/null
  status=${PIPESTATUS[0]}
else
  install_update; status=$?
fi
[ "$status" = 0 ] || fail "$(cat "$tmp/err" 2>/dev/null || echo "Unknown error.")"

[ $ASK = 0 ] && say info "$APP_NAME updated: $current → $latest"
finish 0
