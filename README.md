# update-from-gh-release

Bash script that updates an installed app to the latest GitHub release.
Built for Steam Deck / SteamOS as a Steam launch-options wrapper or a
desktop shortcut — works anywhere with bash, curl, and python3.

## Usage

1. Create a config file pointing to your game dir and the GitHub release info (see [Config](#config)
   for the full list):

   ```sh
   # myapp.conf
   APP_NAME="MyApp"
   REPO="owner/myapp"
   ASSET_PATTERN='^myapp-linux-x86_64\.tar\.gz$'
   INSTALL_DIR="$HOME/Games/MyApp"
   ```

2. Run it:

   ```sh
   # Update your game's Steam launch options:
   /home/deck/bin/update-from-gh-release.sh /home/deck/bin/myapp.conf --ask %command%

   # Or execute standalone, or via cron etc:
   /home/deck/bin/update-from-gh-release.sh /home/deck/bin/myapp.conf
   ```

Keep the script and config file(s) **outside** the install dir (e.g. `~/bin`) so game updates don't overwrite it.

## How it works

- Finds the one release asset matching `ASSET_PATTERN` (regex) and
  compares its tag to the installed version.
- Verifies a checksum asset first, if `CHECKSUM_PATTERN` is set.
- Unpacks the `.tar.*` / `.zip` asset (an archive holding a single folder
  installs that folder's contents) and copies it over the install dir.
- `--ask` mode: checks GitHub on each launch, prompts via zenity, and always
  falls through to launching the game (offline, decline, timeout, errors, or
  no zenity/display all just play).

## Config

One file per app, sourced by the script. See
[`examples/speedbreaker.conf`](examples/speedbreaker.conf).

Required:

| Variable        | Description                                 |
|------------------|----------------------------------------------|
| `APP_NAME`       | Display name used in messages/dialogs.      |
| `REPO`           | `owner/repo` on GitHub.                     |
| `ASSET_PATTERN`  | Regex matching exactly one release asset.   |
| `INSTALL_DIR`    | Where the app is (or will be) installed.    |

Optional:

| Variable              | Description                                               |
|-----------------------|-------------------------------------------------------------|
| `CHECKSUM_PATTERN`    | Regex for a checksum asset; if set, download must verify.  |
| `REQUIRED_FILE`       | Must exist in the new version (layout sanity check).       |
| `RUNNING_MATCH`       | `pgrep -f` pattern; refuses to update while it matches.     |
| `ASK_TIMEOUT`         | Seconds before a dialog closes on its own (default: 10).   |

`GITHUB_TOKEN`, if set in the environment, authenticates GitHub API
requests (avoids rate limiting).

## Requirements

`bash`, `curl`, `python3`, and `unzip` or `bsdtar` (for `.zip` assets).
`zenity` is optional, for dialogs — without it, or without a display (cron,
ssh), messages go to stderr.
