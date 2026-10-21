#!/usr/bin/env bash
# Install claude-restore by symlinking the scripts from this checkout, so the
# repo stays the single copy and edits land in git. --copy installs copies.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
mode=link
[ "${1:-}" = "--copy" ] && mode=copy

BIN="$HOME/.local/bin"
HOOKS="$HOME/.claude/hooks"
ICONS="$HOME/.local/share/icons"
APPS="$HOME/.local/share/applications"
SETTINGS="$HOME/.claude/settings.json"

for dep in python3 jq flock; do
  command -v "$dep" >/dev/null || { echo "missing dependency: $dep" >&2; exit 1; }
done
command -v tilix >/dev/null || command -v gnome-terminal >/dev/null ||
  echo "note: neither tilix nor gnome-terminal found; launching needs one"
for opt in xprop notify-send; do
  command -v "$opt" >/dev/null || echo "note: $opt not found; desktop placement and notifications need it"
done

place() {  # place <source in repo> <target>
  local src="$here/$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  if [ -e "$dst" ] && [ ! -L "$dst" ] && ! cmp -s "$src" "$dst"; then
    cp -p "$dst" "$dst.bak-$(date +%Y%m%d%H%M%S)"
    echo "backed up existing $dst"
  fi
  if [ "$mode" = link ]; then
    ln -sfn "$src" "$dst"
  else
    rm -f "$dst"; cp -p "$src" "$dst"
  fi
  echo "$mode  $dst"
}

place bin/claude-restore          "$BIN/claude-restore"
place bin/claude-restore-desktop  "$BIN/claude-restore-desktop"
place hooks/session-registry.sh   "$HOOKS/session-registry.sh"
place desktop/claude-restore.svg  "$ICONS/claude-restore.svg"

mkdir -p "$APPS"
sed -e "s|@BIN@|$BIN|" -e "s|@ICON@|$ICONS/claude-restore.svg|" \
  "$here/desktop/claude-restore.desktop.in" > "$APPS/claude-restore.desktop"
chmod +x "$APPS/claude-restore.desktop"
echo "wrote $APPS/claude-restore.desktop (copy it to ~/Desktop for a desktop icon)"

mkdir -p "$HOME/.claude/open-sessions"

if [ -f "$SETTINGS" ] && grep -q "session-registry.sh" "$SETTINGS"; then
  echo "hooks already registered in $SETTINGS"
else
  echo
  echo "Register the hook: merge hooks/settings-snippet.json into $SETTINGS"
  echo "(replace \$HOME with your home directory)."
fi

echo
echo "To record sessions that were already running before the hook existed:"
echo "  claude-restore --adopt -n   # preview, then without -n to write"
