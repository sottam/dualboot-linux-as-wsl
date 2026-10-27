# Install

Read [security.md](security.md) first.

## Supported setup

- Windows 11 with WSL 2, a **second disk** used only by Linux (WSL takes the whole disk
  offline in Windows while the distro runs).
- GPT disk; the Linux root is **ext4** on a partition with the generic *Linux filesystem*
  GPT type (`0fc63daf-…`), not encrypted (no LUKS), not LVM/RAID, no btrfs/xfs.
- `/etc/fstab` contains only the root, an optional ESP at `/boot/efi` or `/efi` (vfat) and
  optional swap. Separate `/boot`, `/home`, `/usr` or other filesystems are not supported.
- A systemd distribution. The boot-packages guard needs APT (Debian/Ubuntu family);
  tested on Kubuntu 26.04 with systemd-resolved.
- The stock WSL kernel (no `kernel=` in `.wslconfig`).

## 1. On the native Linux boot: prepare the root

Do this **before** the first WSL launch. A WSL boot without `/etc/wsl.conf` rewrites
`/etc/hostname`, `/etc/hosts` and `/etc/resolv.conf` and mounts the fstab.

1. Back up anything you cannot lose; keep a live USB.
2. Copy this repository to the Linux disk (e.g. `git clone` into your home).
3. Run the installer, dry run first:

   ```bash
   sudo sh tools/linux/install-wsl-side.sh --user "$USER" --dry-run
   sudo sh tools/linux/install-wsl-side.sh --user "$USER" --disable-hibernation
   ```

   It refuses unsupported layouts, then installs the systemd generator, the apt
   boot-packages guard and `/etc/wsl.conf` with your native hostname. Every created or
   replaced file is recorded in `/var/lib/wsl-physical-root/manifest` (backups next to it).
   `--disable-hibernation` masks the hibernate targets: never hibernate the native system
   while the disk is used from WSL; resuming would write stale filesystem state.
4. Shut down completely (not suspend, not hibernate) and boot Windows.

## 2. On Windows: install the patched WSL

Build it first ([build.md](build.md)). Save the official MSI of your current WSL version
for rollback. From an elevated PowerShell:

```powershell
wsl --shutdown
$p = Start-Process msiexec.exe -ArgumentList '/i', "`"$PWD\wsl.msi`"", '/qn', '/norestart', '/l*v', "`"$PWD\wsl-install.log`"" -Wait -PassThru
$p.ExitCode        # 0 = ok, 3010 = ok but reboot required; anything else: read wsl-install.log
wsl --version      # must show your build before you continue
```

Existing VHD distros keep working (same service).

## 3. Register the physical partition

```powershell
Get-Disk
Get-Partition -DiskNumber 1
.\tools\windows\Register-PhysicalRoot.ps1 -DiskNumber 1 -PartitionNumber 2 -DistroName MyLinux
.\tools\windows\Register-PhysicalRoot.ps1 -DiskNumber 1 -PartitionNumber 2 -DistroName MyLinux -Apply
```

Disk/partition numbers are only used to find the disk; the tool stores stable identity
(model and serial read through the same IOCTL the service uses, PARTUUID, ext4 UUID and
feature masks, kernel release, your user SID). It refuses Windows boot/system disks,
non-GPT disks, non-Linux partitions, filesystems that were not shut down cleanly, ext4
features the WSL kernel does not support, a custom kernel in `.wslconfig`, and a name that
already belongs to a regular (VHD) distro.

## 4. First boot

```powershell
wsl -d MyLinux -- systemctl is-system-running --wait
wsl -d MyLinux -- sh -c 'hostname; ls -l /etc/resolv.conf'
```

Expect `running`, your native hostname and the native `resolv.conf` link. If `degraded`,
see [systemd-in-wsl.md](systemd-in-wsl.md) and add units to
`/etc/wsl-physical-root/extra-masks`, then `wsl --shutdown` and start again.
Optional: `wsl --set-default MyLinux`.

## 5. Docker (if the native install has Docker Engine)

Do not run another distro's Docker at the same time: all WSL 2 distros share one network
namespace, so two daemons fight over `docker0` and iptables.

```bash
sudo systemctl start docker
docker run --rm -p 8080:80 nginx   # http://localhost:8080 on Windows
```

## 6. Switching between WSL and the native boot

WSL powers the distro off when Windows logs off or reboots, but systemd gets about ten
seconds before WSL forces it down. Before rebooting into the native system, **stop
stateful workloads** (databases, containers) or run `wsl --shutdown` and wait for it to
return. To stop the distro prefer `wsl --shutdown`
([why](security.md#known-limits)). Then, on the native boot, run `bash tools/linux/native-check.sh`: it checks that
the WSL pieces are inert and that the last WSL boots reached `poweroff.target` (exit 1 on
failure, 2 if no WSL boot was found).

## Rollback

1. Windows: `wsl --shutdown`. As administrator delete
   `HKLM\SOFTWARE\X1Unified\PhysicalRoots\{guid}`, then `wsl --unregister MyLinux`
   (only the registration and its empty metadata directory; the disk is not touched).
2. Windows, elevated: reinstall the official WSL.

   ```powershell
   $i = New-Object -ComObject WindowsInstaller.Installer
   $code = @($i.GetType().InvokeMember('RelatedProducts','GetProperty',$null,$i,@('{6D5B792B-1EDC-4DE9-8EAD-201B820F8E82}')))[0]
   Start-Process msiexec.exe -ArgumentList '/x', $code, '/qn', '/norestart' -Wait
   Start-Process msiexec.exe -ArgumentList '/i', "`"$PWD\wsl.<version>.x64.msi`"", '/qn', '/norestart' -Wait
   wsl --version
   ```

3. Native Linux: `sudo sh tools/linux/uninstall-wsl-side.sh` removes only the files the
   installer created and restores the ones it replaced.
