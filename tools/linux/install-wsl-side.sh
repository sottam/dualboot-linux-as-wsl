#!/bin/sh
# dualboot-linux-as-wsl: prepare the physical root for WSL. Run as root on the NATIVE boot,
# before the first WSL launch (a WSL boot without /etc/wsl.conf rewrites /etc/hostname,
# /etc/hosts and /etc/resolv.conf and mounts the fstab):
#
#     sudo sh tools/linux/install-wsl-side.sh --user <user> [--hostname <name>] [--dry-run]
#                                            [--no-package-guard] [--disable-hibernation]
#
# Checks that the layout is supported, then installs the systemd generator, the apt
# boot-packages guard and /etc/wsl.conf. All of them are inert on the native boot. Every
# file it replaces is backed up and every change is recorded in a manifest used by
# uninstall-wsl-side.sh. Re-running is safe.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
user= host= dry=0 guard=1 nohib=0
while [ $# -gt 0 ]; do
    case "$1" in
        --user) user=$2; shift 2 ;;
        --hostname) host=$2; shift 2 ;;
        --dry-run) dry=1; shift ;;
        --no-package-guard) guard=0; shift ;;
        --disable-hibernation) nohib=1; shift ;;
        *) echo "unknown option: $1"; exit 2 ;;
    esac
done
[ -n "$user" ] || { echo "usage: install-wsl-side.sh --user <user> [--hostname <name>] [--dry-run]"; exit 2; }
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
id "$user" >/dev/null 2>&1 || { echo "no such user: $user"; exit 1; }
fail=0; problem() { echo "REFUSE: $*"; fail=1; }; note() { echo "note:   $*"; }

virt=$(systemd-detect-virt --container 2>/dev/null || true)
if [ "$virt" = wsl ]; then
    note "running under WSL; prefer the native boot (a first WSL boot may already have rewritten hostname/hosts/resolv.conf)"
    [ -n "$host" ] || problem "under WSL /etc/hostname may be the Windows name: pass --hostname <native hostname>"
else
    [ -n "$host" ] || host=$(hostnamectl --static 2>/dev/null || cat /etc/hostname)
fi
for f in "$here/wsl-physical-root-generator" "$here/wsl-boot-packages-guard" "$here/../../examples/wsl.conf"; do
    if grep -q "$(printf '\r')" "$f"; then problem "CRLF line endings in $f (convert to LF)"; fi
done

# --- Supported layout: one ext4 root (not LUKS/LVM/RAID), optional ESP and swap ----------
rootsrc=$(findmnt -no SOURCE /); rootfs=$(findmnt -no FSTYPE /)
[ "$rootfs" = ext4 ] || problem "root filesystem is $rootfs; only ext4 is supported"
case "$rootsrc" in /dev/mapper/*|/dev/dm-*|/dev/md*) problem "root is on $rootsrc (LUKS/LVM/RAID not supported)" ;; esac
unsupported=$(sed -e 's/#.*//' /etc/fstab | awk 'NF>=3 && $2!="/" && !($3=="swap") && !(($2=="/boot/efi"||$2=="/efi") && $3=="vfat") {print $2" ("$3")"}')
[ -z "$unsupported" ] || problem "fstab mounts $(echo $unsupported); separate /boot, /home, /usr and other filesystems are not supported (unavailable, or outside the ext4 gate, under WSL)"

# --- DNS and packages -------------------------------------------------------------------
if [ "$(readlink -f /etc/resolv.conf)" != /run/systemd/resolve/stub-resolv.conf ] || ! systemctl is-enabled systemd-resolved >/dev/null 2>&1; then
    note "systemd-resolved with the stub resolv.conf is not in use: the generator's DNS drop-in will not help; configure /etc/wsl-physical-root/dns or WSL DNS yourself"
fi
if [ "$guard" = 1 ] && ! command -v apt-get >/dev/null; then
    problem "no apt: the boot-packages guard only covers APT. Pass --no-package-guard and never upgrade bootloader/kernel packages from WSL"
fi
if [ "$nohib" = 0 ]; then
    note "never hibernate the native system while the disk is used from WSL (resuming would write stale filesystem state); --disable-hibernation masks the hibernate targets"
fi
[ "$fail" = 0 ] || { echo "Nothing changed."; exit 1; }

echo "Layout OK. hostname=$host user=$user package-guard=$guard disable-hibernation=$nohib"
if [ "$dry" = 1 ]; then echo "Dry run: nothing changed."; exit 0; fi

# --- Install with backups and a manifest ------------------------------------------------
state=/var/lib/wsl-physical-root; stamp=$(date +%Y%m%d-%H%M%S)
mkdir -p "$state/backup-$stamp"; manifest="$state/manifest"; touch "$manifest"
put() { # put <src> <dst> <mode>
    if [ -e "$2" ] && ! cmp -s "$1" "$2"; then
        mkdir -p "$state/backup-$stamp$(dirname "$2")"; cp -p "$2" "$state/backup-$stamp$2"
        echo "replaced $2 backup-$stamp" >> "$manifest"
    elif [ ! -e "$2" ]; then echo "created $2" >> "$manifest"; fi
    install -D -m "$3" "$1" "$2"
}
put "$here/wsl-physical-root-generator" /etc/systemd/system-generators/wsl-physical-root 0755
if [ "$guard" = 1 ]; then
    put "$here/wsl-boot-packages-guard" /usr/local/sbin/wsl-boot-packages-guard 0755
    t=$(mktemp); printf '%s\n' 'DPkg::Pre-Install-Pkgs { "/usr/local/sbin/wsl-boot-packages-guard"; };' \
        'DPkg::Tools::Options::/usr/local/sbin/wsl-boot-packages-guard::Version "2";' > "$t"
    put "$t" /etc/apt/apt.conf.d/50wsl-boot-packages-guard 0644; rm -f "$t"
fi
if [ -e /etc/wsl.conf ]; then
    echo "/etc/wsl.conf exists; left unchanged (compare with examples/wsl.conf)"
else
    t=$(mktemp); sed -e "s/CHANGE-ME-native-hostname/$host/" -e "s/CHANGE-ME-user/$user/" "$here/../../examples/wsl.conf" > "$t"
    put "$t" /etc/wsl.conf 0644; rm -f "$t"
fi
if [ "$nohib" = 1 ]; then
    for t in hibernate.target hybrid-sleep.target suspend-then-hibernate.target; do
        [ -e "/etc/systemd/system/$t" ] || { ln -s /dev/null "/etc/systemd/system/$t"; echo "created /etc/systemd/system/$t" >> "$manifest"; }
    done
fi
sort -u -o "$manifest" "$manifest"; rmdir "$state/backup-$stamp" 2>/dev/null || true
sync
echo "Done. Manifest: $manifest. Now boot Windows and register the partition (docs/install.md)."
