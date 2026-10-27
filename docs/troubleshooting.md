# Troubleshooting

Messages from mini_init land in the VM kernel log. Read them from any other running distro
(`dmesg | grep -i 'physical root'`) or from the physical distro's journal on a later boot.

| Symptom | Meaning | Action |
| --- | --- | --- |
| `Wsl/Service/CreateInstance/E_FAIL` and kmsg `gate was reviewed for kernel X, running Y` | WSL kernel changed | re-run `Register-PhysicalRoot.ps1 -Apply` ([updates.md](updates.md)) |
| kmsg `ext4 features … differ from the reviewed gate` | filesystem features changed | check kernel support, re-register |
| kmsg `does not have the authorized ext4 superblock` / `PARTUUID not found` | wrong or changed partition | check `Get-Partition`, re-register; do not force |
| `X1 physical root disk not found` / `matches more than one disk` | disk absent, renamed or cloned | check `Get-Disk` model/serial |
| `.wslconfig sets a custom kernel` (registration) | only the stock kernel is supported | remove `kernel=` |
| `not shut down cleanly` (registration) | journal recovery pending or native hibernated | boot native, shut down fully |
| `fstab mounts …` (installer) | unsupported layout | see [install.md](install.md#supported-setup) |
| `X1 physical root identity matches the Windows disk` | authorization points at the system disk | fix the registration |
| `WSL_E_DISK_ALREADY_ATTACHED` | disk attached by `wsl --mount` or another registration, or a failed launch | `wsl --shutdown` and retry |
| `WSL_E_ELEVATION_NEEDED_TO_MOUNT_DISK` | running a build without patch 3 | install the full patch series |
| `E_NOTIMPL` on export/move/resize/set-sparse/set-version | refused on purpose for a physical root | — |
| `UnregisterDistro/E_ACCESSDENIED` | refused while authorized | delete the HKLM key as administrator first |
| `wsl --update` refuses (message mentions `docs/WSL-FORK-UPDATES.md`) | patch 6 | see [updates.md](updates.md) |
| kmsg `EXT4-fs error … Remounting filesystem read-only`; journal says `Structure needs cleaning` | ext4 found inconsistent metadata (seen after `wsl --terminate`) | write nothing. `wsl --shutdown`; elevated `wsl --mount \\.\PHYSICALDRIVE<n> --bare`; from another distro, as root: `e2fsck -fn` on the partition (it must not be mounted), keep an `e2image -Q` copy elsewhere, then `e2fsck -fy` and `e2fsck -fn` until it exits 0; `wsl --unmount` |
| `systemctl is-system-running` → `degraded` | a desktop/hardware unit failed under WSL | `systemctl --failed`, add it to `/etc/wsl-physical-root/extra-masks`, `wsl --shutdown` |
| No DNS inside WSL | resolved has no upstream | check `/run/systemd/resolved.conf.d/50-wsl-physical-root.conf`; with `networkingMode=mirrored` set the DNS in `/etc/wsl-physical-root/dns` |
| Native hostname changed to the Windows name | booted once without `wsl.conf` | set `hostname=` in `/etc/wsl.conf`, restore `/etc/hostname` |
| VS Code window: `Unknown reconnection token` | distro was terminated while the window was connected | *Developer: Reload Window* |
| Docker networking conflicts | another distro's Docker is running (shared VM network) | stop the other daemon |
| OpenGL is `llvmpipe` | Mesa does not pick d3d12 without `/dev/dri` | `GALLIUM_DRIVER=d3d12 app`; measure — on an Intel UHD 620 it was slower than llvmpipe |
| `apt` refuses grub/shim/linux-image | `wsl-boot-packages-guard` | upgrade from the native boot |
