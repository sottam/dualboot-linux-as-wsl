#!/bin/bash
# dualboot-linux-as-wsl: run on the native (bare-metal) boot after using the distro from WSL.
# Checks that the WSL-only pieces stayed inert and that the last WSL boot shut down cleanly.
# Writes ~/wsl-native-check-<timestamp>.txt (no secrets); sudo is used for the journal.
set -u
out="$HOME/wsl-native-check-$(date +%Y%m%d-%H%M%S).txt"
ok() { printf 'PASS  %s\n' "$*"; }; bad() { printf 'FAIL  %s\n' "$*"; }
{
[ "$(systemd-detect-virt)" = none ] && ok "bare metal (systemd-detect-virt: none)" || bad "not bare metal: $(systemd-detect-virt)"
[ "$(systemctl is-system-running)" = running ] && ok "systemd running" || bad "systemd: $(systemctl is-system-running); failed: $(systemctl --failed --no-legend | awk '{print $1}' | tr '\n' ' ')"
n=$(ls /run/systemd/generator.early 2>/dev/null | wc -l); [ "$n" = 0 ] && ok "WSL generator inert (no runtime masks)" || bad "$n runtime masks present"
[ -e /run/systemd/resolved.conf.d/50-wsl-physical-root.conf ] && bad "WSL DNS drop-in present" || ok "no WSL DNS drop-in"
findmnt -n /boot/efi >/dev/null && ok "ESP mounted at /boot/efi" || printf 'INFO  /boot/efi not mounted (no ESP entry?)\n'
getent hosts github.com >/dev/null && ok "DNS resolves" || bad "DNS does not resolve"
printf 'INFO  hostname %s, resolv.conf -> %s\n' "$(hostnamectl --static 2>/dev/null || hostname)" "$(readlink /etc/resolv.conf || echo regular-file)"
for b in $(sudo journalctl --list-boots --no-pager -q | awk '{print $1}' | sort -n | tail -6); do
    [ "$b" = 0 ] && continue
    if sudo journalctl -b "$b" -n 400 --no-pager -o cat 2>/dev/null | grep -q 'init-systemd('; then
        sudo journalctl -b "$b" -n 30 --no-pager -o cat | grep -q 'Reached target poweroff.target' &&
            ok "WSL boot $b ended with poweroff.target" || bad "WSL boot $b did not reach poweroff.target"
    fi
done
} | tee "$out"
echo "Report: $out"
