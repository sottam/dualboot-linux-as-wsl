#!/bin/sh
# dualboot-linux-as-wsl: install the WSL-only pieces into the physical root.
# Run as root inside the distro (first boot works without systemd):
#     sudo sh tools/linux/install-wsl-side.sh <default-user>
# Installs the systemd generator, the apt boot-packages guard and /etc/wsl.conf (kept if it
# already exists). All of them are inert on the native boot. Re-running is safe.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
user=${1:?usage: install-wsl-side.sh <default-user>}
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
[ "$(systemd-detect-virt --container 2>/dev/null || true)" = wsl ] || grep -qi microsoft /proc/sys/kernel/osrelease ||
    { echo "not running under WSL; refusing"; exit 1; }
id "$user" >/dev/null 2>&1 || { echo "no such user: $user"; exit 1; }
for f in "$here/wsl-physical-root-generator" "$here/wsl-boot-packages-guard" "$here/../../examples/wsl.conf"; do
    if grep -q "$(printf '\r')" "$f"; then echo "CRLF line endings in $f; convert to LF first"; exit 1; fi
done

install -D -m 0755 "$here/wsl-physical-root-generator" /etc/systemd/system-generators/wsl-physical-root
install -D -m 0755 "$here/wsl-boot-packages-guard" /usr/local/sbin/wsl-boot-packages-guard
if command -v apt-get >/dev/null; then
    printf '%s\n' 'DPkg::Pre-Install-Pkgs { "/usr/local/sbin/wsl-boot-packages-guard"; };' \
        'DPkg::Tools::Options::/usr/local/sbin/wsl-boot-packages-guard::Version "2";' > /etc/apt/apt.conf.d/50wsl-boot-packages-guard
fi
if [ -e /etc/wsl.conf ]; then
    echo "/etc/wsl.conf exists; left unchanged (compare with examples/wsl.conf)"
else
    host=$(cat /etc/hostname 2>/dev/null || hostname)
    sed -e "s/CHANGE-ME-native-hostname/$host/" -e "s/CHANGE-ME-user/$user/" "$here/../../examples/wsl.conf" > /etc/wsl.conf
    chmod 0644 /etc/wsl.conf
    echo "/etc/wsl.conf written (hostname $host, user $user)"
fi
sync
echo "Done. From Windows: wsl --shutdown, then start the distro again to boot with systemd."
