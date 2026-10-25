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
| 1 | Disk resolved at every boot by model **and** serial, exactly one match across all disks (a disk that cannot be inspected aborts), never the disk holding the Windows directory, GPT required, exactly one partition with the PARTUUID and the Linux filesystem type |
| 2 | mini_init finds the GPT slot by PARTUUID inside the attached LUN, checks the ext4 magic and UUID before mounting, and checks the mount's `st_dev` against the partition after |
| 3 | The authorization stores the exact ext4 feature masks and the WSL kernel release; mini_init refuses to mount if either differs. `Register-PhysicalRoot.ps1` checks the masks against `EXT4_FEATURE_INCOMPAT_SUPP` / `RO_COMPAT_SUPP` in that kernel's source before writing |
| 4 | Every image operation is refused for a physical root before touching storage; the only accepted setup message is launch |
| 5 | The authorization lives in **HKLM** (administrators only) and is bound to the user SID; HKCU alone cannot declare a physical root. `wsl --mount` keeps its own elevation requirement |
| 6 | WSL-only behavior is conditional (`wsl.conf`, generator acting only under WSL and only in `/run`); boot-chain packages are refused under WSL |
| 7 | One machine, one boot at a time. While WSL runs, the disk is offline in Windows and attached once; `wsl --mount` of the same disk, and a second registration of the same partition starting while the first holds the disk, are refused |

## Known limits

- No lease across users or VMs beyond the PassThrough attach itself.
- If a launch fails after the attach, the disk stays attached until `wsl --shutdown`
  (the next launch of the same distro reuses it).
- Between resolving the disk on Windows and reopening `\\.\PhysicalDriveN` for the attach
  there is a window in which a disk swap would go unnoticed on the Windows side; the
  Linux-side checks (PARTUUID, UUID, features, kernel) still apply before any mount.
- Other distros in the same VM can see the block device in `/dev`. Mounting the same
  partition again reuses the same kernel superblock (no corruption), but it is not an
  access barrier.
- The patched build is unsigned. It contains no kernel drivers; Smart App Control or a
  WDAC policy can block it.

## Reporting

Open a GitHub issue for bugs. For something that could lead to data loss on other
people's disks, describe it without a working exploit and it will be prioritized.
