# dualboot-linux-as-wsl

**Boot the Linux you already installed on a second disk (dual boot) as a native WSL 2 distro
— same root partition, same home, same packages, same Docker. No VHD copy, no chroot, no nspawn.**

[Português](README.pt-BR.md)

![KDE Konsole opened by WSLg as a Windows window, running from the physical root partition with systemd and Docker](docs/images/wslg-konsole-physical-root.png)

> Status: working prototype on one machine (ThinkPad X1 Carbon Gen 6, Kubuntu 26.04 on a
> second NVMe, Windows 11, WSL 3.0.3). It replaces the WSL service with a patched build.
> Read [Safety](#safety) before trying it.

## Can WSL use a physical Linux partition as the distro root?

Not out of the box. Stock WSL 2 only boots a distro from an `ext4.vhdx` file;
`wsl --mount` can attach a physical disk, but only as an extra mount, never as the
root of a registered distro (see microsoft/WSL
[#6290](https://github.com/microsoft/WSL/issues/6290) and
[#7769](https://github.com/microsoft/WSL/issues/7769)). Workarounds chroot or
`systemd-nspawn` into the partition from another distro, so `wsl.exe`,
`\\wsl.localhost`, VS Code Remote WSL and Docker integration still see the *other*
distro.

This project adds the missing piece to the open-source WSL: a registered distro whose
root is a GPT partition on a pass-through disk. The partition is mounted **before**
WSL's own init starts, so everything after that is unchanged WSL.

## What works

Tested on the real disk, from a normal (non-elevated) Windows session:

| | |
| --- | --- |
| `wsl` / `wsl -d <distro>` | boots the physical root with **systemd** (~10 s cold) |
| `\\wsl.localhost\<distro>` in Explorer | works, and starts the distro from cold |
| VS Code **Remote WSL** | connects, server installed on the physical home |
| **Docker** Engine of the physical install | runs; published ports reach Windows `localhost` |
| **WSLg** | KDE apps open as Windows windows; audio plays on Windows |
| Interop, Windows paths, `systemctl --user` | normal WSL behavior |
| Reboot Windows with the distro open | Linux shuts down cleanly (systemd `poweroff.target`) |
| Boot the same disk on bare metal afterwards | unchanged: desktop, NetworkManager, ESP, Docker |

Full matrix and limits: [docs/results.md](docs/results.md).

## How it works

```text
wsl.exe / Explorer / VS Code
        │
WSL service (patched) ── authorization in HKLM: disk model+serial, PARTUUID,
        │                ext4 UUID + feature masks, WSL kernel release, user SID
        │  resolves the disk, refuses the Windows disk, attaches it as PassThrough
        ▼
WSL VM ── mini_init (patched): finds the GPT slot by PARTUUID, checks the ext4
          superblock and kernel, mounts the partition at /distro
        ▼
stock WSL init ──► systemd of the physical install
                   + a WSL-only systemd generator (masks desktop/network/hardware units in /run)
```

Seven patches on top of WSL tag 3.0.3 (~540 lines, service + mini_init):
[patches/](patches/). Design and code walkthrough: [docs/architecture.md](docs/architecture.md).

The native boot is kept intact by putting every WSL difference behind a condition:
`/etc/wsl.conf` (read only by WSL) and a systemd generator that acts only when
`systemd-detect-virt --container` is `wsl` and writes only to `/run`
([docs/systemd-in-wsl.md](docs/systemd-in-wsl.md)).

## Safety

This boots your real disk read-write from a second kernel. Mistakes can destroy data.

- **Never** run the native system and the WSL distro at the same time (they cannot be,
  on the same machine — but do not copy this to a setup where they could).
- The registration tool refuses Windows boot/system disks, non-GPT disks and
  non-Linux partitions, and the patched service re-checks identity at every boot.
- The ext4 features on disk are checked against the source of the exact WSL kernel;
  a new WSL kernel or a changed filesystem blocks the boot until you re-register.
- `wsl --export`, `--import` paths, `--manage --move/--resize/--set-sparse`,
  `--set-version` and `--unregister` are refused for the physical distro: there is no
  image, only your disk.
- Boot-chain packages (GRUB, shim, kernels) must be upgraded from the native boot; an
  APT hook refuses them under WSL (`dpkg -i` is not covered).
- **Never hibernate** the native system while the disk is used from WSL, and shut it down
  fully before booting Windows. Registration refuses a filesystem that was not shut down
  cleanly.
- Supported layout only: GPT, plain ext4 root (no LUKS/LVM/RAID), fstab with just the
  root, ESP and swap ([docs/install.md](docs/install.md#supported-setup)).
- Have a backup and a live USB before trying. Threat model: [docs/security.md](docs/security.md).

## Quick start

1. **On the native Linux boot**, prepare the root (dry run first), then shut down fully:

   ```bash
   sudo sh tools/linux/install-wsl-side.sh --user "$USER" --dry-run
   sudo sh tools/linux/install-wsl-side.sh --user "$USER" --disable-hibernation
   ```

2. **Build** the patched WSL on Windows (Visual Studio 2022 + CMake; ~10 min on a fast
   desktop): [docs/build.md](docs/build.md). No binaries are published on purpose.
3. **Install** it over your WSL with `msiexec` and keep the official MSI for rollback.
4. **Register** the partition from an elevated PowerShell (dry run without `-Apply`):

   ```powershell
   Get-Disk; Get-Partition -DiskNumber 1
   .\tools\windows\Register-PhysicalRoot.ps1 -DiskNumber 1 -PartitionNumber 2 -DistroName MyLinux
   .\tools\windows\Register-PhysicalRoot.ps1 -DiskNumber 1 -PartitionNumber 2 -DistroName MyLinux -Apply
   ```

5. **Boot** it: `wsl -d MyLinux`.

Step by step, with checks and rollback: [docs/install.md](docs/install.md).

## Documentation

| | |
| --- | --- |
| [architecture.md](docs/architecture.md) | design, boot flow, what each patch changes |
| [build.md](docs/build.md) | building the patched WSL (and the pitfalls we hit) |
| [install.md](docs/install.md) | install, register, first boot, Docker, rollback |
| [systemd-in-wsl.md](docs/systemd-in-wsl.md) | running a desktop install's systemd under WSL without breaking the native boot |
| [security.md](docs/security.md) | authorization model, checks, refused operations, known limits |
| [updates.md](docs/updates.md) | WSL updates, kernel changes, rebasing the patches |
| [troubleshooting.md](docs/troubleshooting.md) | errors and what they mean |
| [results.md](docs/results.md) | test matrix from the real machine |

## FAQ

**Is this the same as `wsl --mount`?** No. `wsl --mount` adds a disk to a running distro.
Here the partition *is* the distro root, so every WSL feature talks to it directly.

**Do I need a custom Linux kernel?** No. The stock WSL kernel is used; WSL chooses the
distro root in its service and init, not in the kernel.

**Does it work with a disk Windows also uses?** No. The whole disk is taken offline in
Windows while the distro runs. Use a second disk dedicated to Linux.

**Which distros?** Tested with Kubuntu 26.04 (ext4, systemd). Other systemd distros on
ext4 should work; the generator's mask list may need additions for their units.

**Is the patched WSL signed?** No. It contains no kernel drivers, so Windows does not
require a signature for it; Smart App Control or WDAC policies may still block it.

**Will Microsoft support this?** Not now. A proposal will be posted on
[#6290](https://github.com/microsoft/WSL/issues/6290); the goal is an upstream feature so
nobody has to maintain a fork.

**Can I go back?** Yes: reinstall the official WSL MSI and remove the registration
([docs/install.md](docs/install.md#rollback)). The native boot never depended on it.

## License

MIT for the scripts and documentation in this repository. The patches modify
[microsoft/WSL](https://github.com/microsoft/WSL), which is MIT licensed.
Not affiliated with or endorsed by Microsoft.
