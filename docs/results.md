# Test results (October 2026)

Machine: ThinkPad X1 Carbon Gen 6 (i7-8650U, 16 GB), Windows 11 Pro 26200 on the main
NVMe; Kubuntu 26.04.1 (systemd 259, Docker Engine 29.9.1) on a second NVMe in the WWAN slot
(GPT: 1 GiB ESP + ext4 root). WSL 3.0.3 built from source with the patches in this repo,
WSL kernel 6.18.54.1. Native kernel 7.0.0-38-generic.

These results come from the original project's versions of the tools. The public
`Register-PhysicalRoot.ps1` was validated against that installation (dry run produced the
same authorization values; the negative cases below were run with it), and the public
generator produced the same masks plus generic extras. The machine was then migrated to
the public `install-wsl-side.sh`, generator and apt guard: systemd `running` with no failed
units, DNS, Docker and the apt refusal all re-checked. The patches are the tested series
(only the author e-mail in the headers differs).

After an independent review the tools gained stricter preflight checks (supported
layouts, unclean or hibernated filesystems, custom kernels, masking of every non-root
fstab mount). Those revisions were tested with dry runs on this machine, a real
install/uninstall on a scratch distro and the negative cases; the generator with fstab
masking runs on the physical root.

## Boot and integration

| Test | Result |
| --- | --- |
| `wsl -d` cold start, not elevated | systemd `running` in ~9–10 s, no failed units |
| Root mount | the physical partition (`/dev/sdX2`), no `discard`, `errors=remount-ro` |
| `\\wsl.localhost\<distro>` cold start from Explorer/PowerShell | listing in ~4 s; files written from Windows owned by the Linux user |
| VS Code 1.143 + Remote WSL 0.104 | connects cold (VM stopped) and warm; server lives on the physical home |
| Docker Engine (data of the physical install) | starts on first use (`docker.socket`); a container ran on the 6.18 kernel; `-p` port reachable on Windows `localhost` |
| WSLg | X11 and Wayland; KDE apps (kcalc) open as Windows windows; audio heard on Windows through `RDPSink` |
| GPU | `GALLIUM_DRIVER=d3d12` → "D3D12 (Intel UHD Graphics 620)"; glxgears 19 FPS vs 139 FPS llvmpipe at 1600x900, so llvmpipe stays default |
| Interop | Windows executables run from the distro |
| DNS | systemd-resolved through the WSL DNS tunnel; native `resolv.conf` symlink untouched |
| `wsl --terminate` then start again | root LUN reused; **once (2026-10-26) this left ext4 with inconsistent bitmaps** and the root read-only. With patch 7: 50 rounds on a fixture VHD with continuous writes, mini_init waited 100–300 ms for the previous instance every time, no ext4 errors, clean offline `e2fsck` — see [security.md](security.md#known-limits) |
| Reboot Windows with the distro open | journal of that WSL boot ends with `poweroff.target` / "Shutting down" |
| `wsl --shutdown` | full systemd poweroff; next mount without journal recovery |

## Refusals

| Operation | Result |
| --- | --- |
| `--export`, `--manage --resize`, `--manage --set-sparse`, `--manage --move`, `--set-version 1` | `E_NOTIMPL`, nothing written |
| `--unregister` while authorized | `E_ACCESSDENIED`, registration intact |
| Authorization with modified ext4 masks | boot refused before mount, kmsg explains |
| Authorization with another kernel release | boot refused before mount, kmsg explains |
| `wsl --update` | refused |
| Registration tool on the ESP / the Windows disk / a missing partition | refused |
| apt reinstall of a boot-chain package under WSL | refused by the APT hook; ordinary packages pass |

## Native boot afterwards

Same machine rebooted into Kubuntu: `systemd-detect-virt` = `none`, systemd `running`
with no failed units, SDDM and NetworkManager active, ESP mounted, no runtime masks,
DNS and HTTPS working, Docker data intact, files written from WSL present with the same
hashes.

## ext4 cross-kernel checks

Before the first read-write boot on a new kernel, an image with the same features was
exercised (writes, fsync, rename, xattrs, hardlinks, open-unlinked files, `e2fsck -n`) on
the WSL kernel and verified under the native kernel in QEMU, in both directions. The
registration tool now automates the feature part of that check against the WSL kernel
source; the full fixture is recommended when moving to a new kernel series.
