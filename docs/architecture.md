# Architecture

## Where WSL chooses the distro root

WSL 2 runs every distro in one lightweight utility VM with one kernel. The root of a
distro is decided by two user-mode components, both open source since 2025:

1. **The Windows service** (`wslservice.exe`). `WslCoreVm::CreateInstance` attaches the
   distro's `ext4.vhdx` to the VM as a SCSI disk (`DiskType::VHD`) and sends
   `LX_MINI_INIT_MESSAGE` with the LUN.
2. **`mini_init`** inside the VM. It mounts that LUN at `/distro`, binds the WSL `init`
   into it, chroots and starts the distro's init. `init` then sets up interop, the Plan 9
   server behind `\\wsl.localhost`, WSLg sockets and, if enabled, systemd.

The kernel does not take part in this choice, so a custom kernel cannot change the root.
Mounting a different root *after* `init` runs does not work either: the Plan 9 server and
init already hold the old root (`pivot_root` from inside a distro was tried and fails).
The root has to be right before `init` starts.

WSL already contains the other half: `wsl --mount` attaches a physical disk with
`DiskType::PassThrough` (HCS `AttachmentType::PassThru`) and takes it offline in Windows.

## What the patches change

| Patch | Component | Change |
| --- | --- | --- |
| 1 | service | `LXSS_PHYSICAL_ROOT` read from an administrator-owned HKLM key named after the distro GUID; `CreateInstance` resolves the disk (exactly one disk with the model+serial, not the disk holding the Windows directory, GPT, one Linux-type partition with the PARTUUID), attaches it as PassThrough and passes the partition identity in a new `PhysicalRootOffset` field; no online `discard` |
| 1 | mini_init | `MountPhysicalRoot`: checks the ext4 magic and UUID, mounts the partition at `/distro`, verifies `st_dev` of the mount against `st_rdev` of the partition |
| 2 | both | review fixes: the GPT slot is found by PARTUUID inside the LUN (Windows partition numbers can differ from Linux slots); an invalid authorization no longer breaks `wsl --list`; strict parsing; read-only flag refused |
| 3 | service | identity resolution and attach run as the service (`wil::run_as_self`), so a non-elevated cold start (CLI, UNC, VS Code) works; the HKLM authorization replaces per-call elevation |
| 4 | both | Move/Export/SetSparse/Resize/Compact/SetVersion refused (`E_NOTIMPL`); after `--terminate` the root LUN is reused; mini_init compares the superblock feature masks and `uname -r` with the authorized ones before mounting |
| 5 | both | LUN reuse only for the distro that attached it; `--unregister` refused while authorized; runtime bits (`RECOVER`, `ORPHAN_PRESENT`) ignored on both sides |
| 6 | client | `wsl --update`, package repair and the SDK update path refuse unless `X1_ALLOW_WSL_UPDATE=1` |
| 7 | mini_init | before reading the superblock, wait until the partition can be opened `O_EXCL` (up to 30 s): after `--terminate` the previous instance only releases the root while the next launch is already running; refuse the launch if it stays busy |

"X1" is the codename of the original project; the registry path is
`HKLM\SOFTWARE\X1Unified\PhysicalRoots\{distro-guid}`.

## Boot flow

```text
wsl -d MyLinux  (any user, not elevated)
 └─ service: read HKCU registration + HKLM authorization (refuse if invalid or other SID)
    └─ run as service: find disk by model+serial, refuse Windows disk, check GPT + PARTUUID
       └─ attach PhysicalDriveN as PassThrough (disk goes offline in Windows)
          └─ message to mini_init: "<PARTUUID>:<ext4 UUID>:<compat>:<incompat>:<ro_compat>:<kernel>"
             └─ mini_init: kernel == authorized? GPT slot with PARTUUID? Linux type?
                ext4 magic + UUID + feature masks == authorized? → mount /dev/sdX<n> at /distro
                └─ stock WSL init → systemd of the physical install
```

## Shared `/etc`, two environments

The physical install keeps one `/etc`. WSL-specific behavior lives only in:

- `/etc/wsl.conf` — read only by WSL: systemd on, the native hostname, no generated
  `resolv.conf`/`hosts`, no fstab mounts, default user.
- `/etc/systemd/system-generators/wsl-physical-root` — exits on bare metal; under WSL it
  masks units in `/run/systemd/generator.early` and points systemd-resolved at the WSL DNS.
- `/usr/local/sbin/wsl-boot-packages-guard` + an apt hook — refuses boot-chain packages
  under WSL.

Details: [systemd-in-wsl.md](systemd-in-wsl.md).

## Why not a VHDX on a shared disk, or nspawn?

- **VHDX shared with the native boot**: Linux has no in-kernel VHDX driver; booting bare
  metal from it needs qemu-nbd or loop tricks in the initramfs, on NTFS. Fragile and slow.
- **chroot/nspawn from a helper distro**: works for a shell and even Docker, but WSL's
  own entry points (`wsl --exec`, `\\wsl.localhost`, Remote WSL, Dev Containers) still
  land in the helper distro, so every integration needs a bridge. This project started
  there and replaced it.
