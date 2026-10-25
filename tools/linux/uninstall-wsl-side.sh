#!/bin/sh
# dualboot-linux-as-wsl: undo install-wsl-side.sh. Run as root (native boot recommended).
# Removes only the files the installer created and restores the files it replaced.
set -eu
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
state=/var/lib/wsl-physical-root; manifest="$state/manifest"
[ -r "$manifest" ] || { echo "no manifest at $manifest; nothing to undo"; exit 1; }
while read -r action path backup; do
    case "$action" in
        created) rm -f "$path" && echo "removed $path" ;;
        replaced) cp -p "$state/$backup$path" "$path" && echo "restored $path from $backup" ;;
    esac
done < "$manifest"
mv "$manifest" "$manifest.undone-$(date +%Y%m%d-%H%M%S)"
echo "Done. Directories under $state are kept for reference."
