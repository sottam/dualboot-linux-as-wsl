#!/bin/bash
# dualboot-linux-as-wsl: run on the native (bare-metal) boot after using the distro from WSL:
#     bash tools/linux/native-check.sh
# Checks that the WSL-only pieces stayed inert and that recent WSL boots shut down cleanly.
# Writes ~/wsl-native-check-<timestamp>.txt (no secrets); sudo is used for the journal.
# Exit status: 0 all checks passed, 1 a check failed, 2 inconclusive (no WSL boot found).
set -u
export LC_ALL=C
out="$HOME/wsl-native-check-$(date +%Y%m%d-%H%M%S).txt"
# systemd "unit started" message: language-independent way to find "Reached target poweroff.target".
UNIT_STARTED=39f53479d3a045ac8e11786248231fbf
fails=0 wsl_boots=0
ok() { printf 'PASS  %s\n' "$*"; }; bad() { printf 'FAIL  %s\n' "$*"; fails=$((fails + 1)); }; info() { printf 'INFO  %s\n' "$*"; }

exec > >(tee "$out") 2>&1
[ "$(systemd-detect-virt)" = none ] && ok "bare metal (systemd-detect-virt: none)" || bad "not bare metal: $(systemd-detect-virt)"
state=$(systemctl is-system-running)
[ "$state" = running ] && ok "systemd running" || bad "systemd $state; failed: $(systemctl --failed --no-legend | awk '{print $1}' | tr '\n' ' ')"
n=$(ls /run/systemd/generator.early 2>/dev/null | wc -l)
[ "$n" = 0 ] && ok "WSL generator inert (no runtime masks)" || bad "$n runtime masks present"
[ -e /run/systemd/resolved.conf.d/50-wsl-physical-root.conf ] && bad "WSL DNS drop-in present" || ok "no WSL DNS drop-in"
if findmnt -n /boot/efi >/dev/null || findmnt -n /efi >/dev/null; then ok "ESP mounted"; else info "no ESP mounted"; fi
getent hosts github.com >/dev/null && ok "DNS resolves" || bad "DNS does not resolve"
info "hostname $(hostnamectl --static 2>/dev/null || hostname); resolv.conf -> $(readlink /etc/resolv.conf || echo regular-file)"

# WSL boots are recognized by the WSL kernel command line; check the most recent five.
for b in $(sudo journalctl --list-boots --no-pager -q 2>/dev/null | awk '$1 < 0 {print $1}' | sort -rn | head -20); do
    sudo journalctl -b "$b" -k -q --no-pager -g 'WSL_ROOT_INIT' -n 1 >/dev/null 2>&1 || continue
    wsl_boots=$((wsl_boots + 1))
    if [ -n "$(sudo journalctl -b "$b" -q --no-pager -o cat MESSAGE_ID=$UNIT_STARTED UNIT=poweroff.target 2>/dev/null)" ]; then
        ok "WSL boot $b reached poweroff.target"
    else
        bad "WSL boot $b did not reach poweroff.target (unclean shutdown)"
    fi
    [ "$wsl_boots" -ge 5 ] && break
done
[ "$wsl_boots" -gt 0 ] || info "no WSL boot found in the journal (persistent journal off, or never booted from WSL): shutdown check inconclusive"

echo "Report: $out"
[ "$fails" -gt 0 ] && exit 1
[ "$wsl_boots" -gt 0 ] || exit 2
exit 0
