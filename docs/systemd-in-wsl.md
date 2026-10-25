# A desktop install's systemd under WSL

A dual-boot install expects a display manager, a network manager, the ESP, swap, firmware
updaters and so on. Under WSL most of that is wrong or harmful: WSL owns the network of
the whole VM (shared by all distros), there is no GPU/DRM device, no EFI NVRAM and the ESP
must not be touched. The same `/etc` has to keep working on bare metal.

## The generator

`tools/linux/wsl-physical-root-generator`, installed as
`/etc/systemd/system-generators/wsl-physical-root`:

- Exits immediately unless `systemd-detect-virt --container` prints `wsl` (bare metal
  prints `none`; a systemd-nspawn container prints `systemd-nspawn`).
- Masks units by symlinking them to `/dev/null` in `/run/systemd/generator.early`, which
  takes precedence over `/etc`. Nothing in `/etc` is enabled or disabled.
- Writes `/run/systemd/resolved.conf.d/50-wsl-physical-root.conf` with `DNS=10.255.255.254`
  (the WSL DNS tunnel in NAT mode) so systemd-resolved works with the native
  `resolv.conf → stub-resolv.conf` symlink untouched.

Masked by default (only units that exist matter): display managers and GPU setup, Plymouth,
`getty@tty1`, NetworkManager/ModemManager/wpa_supplicant/networkd/netplan, VPN and firewall
services, cloud-init, Bluetooth/power/thermal/sensors/SMART, multipath/iSCSI/LVM monitors,
udisks2, chrony/timesyncd (the VM clock is synced by Hyper-V), GRUB/initrd maintenance,
**`boot-efi.mount`** and `systemd-fsck-root`, unattended upgrades and update timers, fwupd,
crash reporters, CUPS and snapd.

Configuration in `/etc/wsl-physical-root/` (one item per line, `#` comments):
`extra-masks` (add), `keep` (remove from the default list), `dns` (override; an empty file
disables the resolved drop-in).

On Kubuntu 26.04 this gives `systemctl is-system-running` = `running` with no failed units.

## /etc/wsl.conf

```ini
[boot]
systemd=true
[network]
hostname=<native hostname>     # WSL rewrites /etc/hostname at every boot
generateResolvConf=false       # keep the native resolv.conf symlink
generateHosts=false            # keep the native /etc/hosts
[automount]
mountFsTab=false               # WSL init must not mount the ESP/swap from fstab
[user]
default=<user>
```

`mountFsTab=false` only stops WSL's init; systemd's fstab generator still creates
`boot-efi.mount`, which is why the generator masks it.

## Boot-chain packages

With the ESP unmounted and no EFI variables, a GRUB/shim/kernel upgrade inside WSL would
write EFI files into the empty `/boot/efi` directory of the root filesystem. The native
boot would then run an old GRUB core from the ESP with new modules from `/boot/grub` — a
classic way to end up unbootable. `wsl-boot-packages-guard` (a dpkg pre-install hook)
refuses `grub*`, `shim*`, `linux-image*`, `linux-signed*`, `linux-modules*`,
`initramfs-tools`, `dracut`, `systemd-boot`, `efibootmgr`, `fwupd`, `mokutil` and
`sbsigntool` under WSL; upgrade them from the native boot. `WSL_ALLOW_BOOT_PACKAGES=1`
overrides deliberately.

## Side effects WSL still has on the root

- `/init` (empty file): WSL bind-mounts its init there at every boot. Harmless natively.
- `/etc/ld.so.conf.d/ld.wsl.conf` and an `ldconfig` run that adds `/usr/lib/wsl/lib`
  to the cache (missing natively, harmless). `[automount] ldconfig=false` disables it.
- WSLg adds Start-menu shortcuts in Windows for the distro's `.desktop` files.

## Sharing state between the two boots

Same files, same Docker data (`/var/lib/docker`), same journal: `journalctl --list-boots`
on bare metal also lists the WSL boots, which is how `native-check.sh` verifies that WSL
shut down cleanly.
