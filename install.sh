#!/usr/bin/env bash
# cfctx installer — idempotent. Intended to be run from a local clone:
#
#   git clone https://github.com/<you>/cfctx.git
#   cd cfctx
#   bash install.sh
#
# You can also run it with CFCTX_REPO set to an arbitrary raw-git prefix
# for curl-pipe-style installs, but the preferred path is a clone — it
# keeps completions, docs, and tests available locally.

set -euo pipefail

: "${CFCTX_INSTALL_DIR:=$HOME/.local/share/cfctx}"
: "${CFCTX_BRANCH:=main}"
: "${CFCTX_REPO:=}"
SOURCE_URL=""
[[ -n "$CFCTX_REPO" ]] && SOURCE_URL="$CFCTX_REPO/$CFCTX_BRANCH/cfctx.sh"

log()  { printf '\033[36m[cfctx]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[cfctx]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[cfctx]\033[0m %s\n' "$*" >&2; exit 1; }

mkdir -p "$CFCTX_INSTALL_DIR"
target="$CFCTX_INSTALL_DIR/cfctx.sh"

# 1. Place cfctx.sh. Prefer a local copy (running from a clone).
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [[ -f "$SCRIPT_DIR/cfctx.sh" ]]; then
    log "Copying local cfctx.sh → $target"
    cp "$SCRIPT_DIR/cfctx.sh" "$target"
elif [[ -n "$SOURCE_URL" ]]; then
    if command -v curl >/dev/null 2>&1; then
        log "Downloading cfctx.sh from $SOURCE_URL"
        curl -fsSL "$SOURCE_URL" -o "$target" || die "Download failed"
    elif command -v wget >/dev/null 2>&1; then
        log "Downloading cfctx.sh from $SOURCE_URL"
        wget -qO "$target" "$SOURCE_URL" || die "Download failed"
    else
        die "Need curl or wget for remote install."
    fi
else
    die "No cfctx.sh found next to install.sh and CFCTX_REPO is not set. Clone the repo first or pass CFCTX_REPO=<raw-prefix>."
fi
chmod 644 "$target"

# 2. Work out which rc file to touch.
pick_rc() {
    local shell_name
    shell_name=$(basename "${SHELL:-}")
    case "$shell_name" in
        zsh)  echo "$HOME/.zshrc" ;;
        bash)
            # macOS loads ~/.bash_profile for login shells; Linux prefers ~/.bashrc
            if [[ "$(uname -s)" == "Darwin" && -f "$HOME/.bash_profile" ]]; then
                echo "$HOME/.bash_profile"
            else
                echo "$HOME/.bashrc"
            fi
            ;;
        *)
            warn "Unrecognised shell '$shell_name'. Defaulting to ~/.profile"
            echo "$HOME/.profile"
            ;;
    esac
}
rc_file=$(pick_rc)
source_line="source \"$target\""
marker="# >>> cfctx >>>"

# 3. Append idempotently.
touch "$rc_file"
if grep -Fq "$marker" "$rc_file"; then
    log "$rc_file already wired up — skipping."
else
    {
        echo ""
        echo "$marker"
        echo "$source_line"
        echo "# <<< cfctx <<<"
    } >> "$rc_file"
    log "Appended source line to $rc_file"
fi

log "Done. Open a new terminal (or run: source \"$target\") and try: cfctx help"
