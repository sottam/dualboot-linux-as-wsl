# Install

Assumes: Windows 11, a second disk with a GPT Linux install (root on ext4, systemd), the
native install already boots and shuts down cleanly, and you built the MSI
([build.md](build.md)). Read [security.md](security.md) first.

## 0. Before you start

- Back up anything on the Linux disk you cannot lose, and keep a live USB.
- Shut the native Linux down **cleanly** (a pending journal recovery is reported and
  should be cleared by one clean native boot).
- Disable Fast Startup / hibernation if Windows shares a disk with Linux.
- Save the official MSI of your current WSL version for rollback.
- Note your native hostname and user (`hostnamectl --static`, `id -un`).

## 1. Install the patched WSL

```powershell
wsl --shutdown
msiexec /i path\to\wsl.msi /qn /norestart /l*v wsl-install.log
wsl --version        # shows the commit of your build
```

Existing VHD distros keep working (they use the same service). The kernel version
changes only if your previous WSL was older than 3.0.3.

## 2. Register the physical partition

Find the disk and partition **numbers** Windows uses (not stable across reboots; the
tool converts them into stable identity):

```powershell
Get-Disk
Get-Partition -DiskNumber 1
```

From an elevated PowerShell, dry run first, then apply:

```powershell
.\tools\windows\Register-PhysicalRoot.ps1 -DiskNumber 1 -PartitionNumber 2 -DistroName MyLinux
.\tools\windows\Register-PhysicalRoot.ps1 -DiskNumber 1 -PartitionNumber 2 -DistroName MyLinux -Apply
```

The dry run prints the disk model, PARTUUID, ext4 UUID and feature masks, the WSL
kernel release and whether every INCOMPAT/RO_COMPAT feature is supported by that
kernel's source. It refuses Windows boot/system disks, non-GPT disks and non-Linux
partitions. `-Apply` writes the HKLM authorization and a normal HKCU distro
registration (no VHD, `BasePath` holds only metadata).

## 3. First boot and WSL-only pieces

The first boot runs without systemd (no `/etc/wsl.conf` yet). WSL's init always rewrites
`/etc/hostname`, and without a `wsl.conf` it also rewrites `/etc/resolv.conf` and
`/etc/hosts` — so install the pieces right away and check those three files afterwards.

```powershell
wsl -d MyLinux -u root -- sh /mnt/c/path/to/dualboot-linux-as-wsl/tools/linux/install-wsl-side.sh youruser
```

This installs `/etc/systemd/system-generators/wsl-physical-root`, the apt hook
`wsl-boot-packages-guard` and `/etc/wsl.conf` (systemd, native hostname, no generated
resolv.conf/hosts, no fstab, default user). Then:

```powershell
wsl -d MyLinux -u root -- sh -c 'cat /etc/hostname; ls -l /etc/resolv.conf'
wsl --shutdown
wsl -d MyLinux -- systemctl is-system-running --wait
```

Expect `running`. If `degraded`, see [systemd-in-wsl.md](systemd-in-wsl.md) for units to
add to `/etc/wsl-physical-root/extra-masks`.

Optional: `wsl --set-default MyLinux`.

## 4. Docker (if the native install has Docker Engine)

Do not run another distro's Docker at the same time: all WSL 2 distros share one network
namespace, so two daemons fight over `docker0` and iptables.

```bash
sudo systemctl start docker
docker run --rm -p 8080:80 nginx   # reachable from Windows at http://localhost:8080
```

## 5. Check the native boot

Reboot into the native system (no need to `wsl --shutdown` first) and run
`tools/linux/native-check.sh`. It checks that the generator is inert, the ESP is mounted,
DNS works and that the last WSL boot ended with `poweroff.target`.

## Rollback

1. `wsl --shutdown`
2. As administrator: delete `HKLM\SOFTWARE\X1Unified\PhysicalRoots\{guid}`, then
   `wsl --unregister MyLinux` (only the registration; the disk is not touched).
3. `msiexec /x` the patched WSL, `msiexec /i` the official MSI.
4. Optional, in the native system: remove `/etc/wsl.conf`, the generator, the guard and
   `/etc/apt/apt.conf.d/50wsl-boot-packages-guard` (all inert there).
