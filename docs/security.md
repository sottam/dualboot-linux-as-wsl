# Security and safety model

## What could go wrong

1. The service attaches the **wrong disk** (e.g. the Windows disk) to the VM.
2. The VM mounts a partition that is not the intended root, or a clone of it.
3. A kernel that does not fully support the on-disk ext4 features mounts it read-write.
4. An image operation meant for VHD distros (format on import, resize, compact, move,
   export, set-version) runs against the real disk.
5. A non-administrator abuses the service (which runs as LocalSystem) to attach an
   arbitrary disk.
6. The native boot is damaged by WSL-side changes in the shared `/etc` or `/boot`.
7. Both systems use the disk at the same time.

## Controls

| Risk | Control |
| --- | --- |
| 1 | Disk resolved at every boot by model **and** serial, exactly one match among `PhysicalDrive0`–`PhysicalDrive255` (a disk that cannot be inspected aborts), never the disk holding the Windows directory, GPT required, exactly one partition with the PARTUUID and the Linux filesystem type |
| 2 | mini_init finds the GPT slot by PARTUUID inside the attached LUN, checks the ext4 magic and UUID before mounting, and checks the mount's `st_dev` against the partition after |
| 3 | The authorization stores the exact ext4 feature masks and the WSL kernel release string; mini_init refuses to mount if either differs. `Register-PhysicalRoot.ps1` checks the masks against `EXT4_FEATURE_INCOMPAT_SUPP` / `RO_COMPAT_SUPP` in the source of the **stock** kernel shipped in the WSL package and refuses a `kernel=` override in `.wslconfig`. The boot-time check compares the release string only: a custom kernel with the same string would not be detected |
| 4 | Every image operation is refused for a physical root before touching storage; the only accepted setup message is launch |
| 5 | The authorization lives in **HKLM** (administrators only) and is bound to the user SID; HKCU alone cannot declare a physical root. `wsl --mount` keeps its own elevation requirement |
| 6 | WSL-only behavior is conditional (`wsl.conf`, generator acting only under WSL and only in `/run`, masking every fstab mount except the root); the root is prepared from the native boot before the first WSL launch; boot-chain packages are refused under WSL by an **APT** hook (direct `dpkg -i` and non-APT distros are not covered) |
| 7 | One machine, one boot at a time; registration refuses a filesystem that was not shut down cleanly (including a hibernated native system), and the installer can mask hibernation. While WSL runs, the disk is offline in Windows and attached once; `wsl --mount` of the same disk, and a second registration of the same partition starting while the first holds the disk, are refused |

## Known limits

- **Prefer `wsl --shutdown` to stop the physical distro.** On 2026-10-26 a
  `--terminate` followed by an immediate relaunch (which reuses the attached disk) left
  the ext4 root with inconsistent block/inode bitmaps; the kernel remounted it
  read-only and an offline `e2fsck` repaired it without data loss
  ([troubleshooting](troubleshooting.md)). A fixture test showed why the two can
  overlap: after `--terminate` the previous instance keeps the root mounted until the
  next launch is already reading its superblock. Patch 7 makes mini_init wait until
  the partition is free; with it, 50 terminate/relaunch rounds under continuous writes
  and a unit that stops slower than WSL waits showed no overlap, no ext4 errors and a
  clean offline `e2fsck` (without it: overlap in every round, journal replay in 40 of
  50, still no errors). The exact trigger of the 2026-10-26 corruption was not
  reproduced, and terminate on a real disk has not been accepted yet.

- No lease across users or VMs beyond the PassThrough attach itself.
- If a launch fails after the attach, the disk stays attached until `wsl --shutdown`
  (the next launch of the same distro reuses it).
- Between resolving the disk on Windows and reopening `\\.\PhysicalDriveN` for the attach
  there is a window in which a disk swap would go unnoticed on the Windows side; the
  Linux-side checks (PARTUUID, UUID, features, kernel) still apply before any mount.
- Other distros in the same VM can see the block device in `/dev`; nothing stops them
  from mounting the partition. Do not do that while the physical distro runs.
- Disks numbered above `PhysicalDrive255` are not considered by the service's uniqueness check.
- The WSLC SDK update path can still try Windows Update before the patch-6 guard (v0.1).
- WSL forces the distro down about ten seconds after asking systemd to power off; stop
  stateful workloads before switching boots.
- The patched build is unsigned. It contains no kernel drivers; Smart App Control or a
  WDAC policy can block it.

## Reporting

Open a GitHub issue for bugs. For something that could lead to data loss on other
people's disks, describe it without a working exploit and it will be prioritized.
