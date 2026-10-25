# WSL updates and kernel changes

The physical distro only boots on the patched WSL, and only with the WSL kernel it was
registered for. Both are deliberate.

## Protections

- Patch 6 makes `wsl --update`, the package repair path and the SDK update refuse with a
  message, unless `X1_ALLOW_WSL_UPDATE=1` is set in the environment.
- Optional: `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Lxss\UpdateCheckPeriodMs = 0`
  (DWORD) disables the service's update notification (only active in official builds).
- An official MSI installed by hand or by a third party is not blocked. If that happens
  the physical distro fails to start (the official service looks for an `ext4.vhdx` that
  does not exist) and the disk is not touched. Reinstall the patched MSI.

## When a new WSL release comes out

1. Rebase: `git checkout <new-tag>` in your WSL clone, `git am patches/*.patch`, resolve
   conflicts (the touched areas are `WslCoreVm.cpp`, `LxssUserSession.cpp`,
   `LxssCreateProcess.h`, `lxinitshared.h`, `src/linux/init/main.cpp`, `install.cpp`).
2. Build and install ([build.md](build.md)).
3. If the kernel changed, the distro now refuses to boot:
   `gate was reviewed for kernel X, running Y`. Re-run
   `Register-PhysicalRoot.ps1 ... -Apply`: it reads the new kernel release, checks the
   on-disk ext4 features against that kernel's source and updates the authorization.
4. Boot and run the checks in [install.md](install.md#3-first-boot-and-wsl-only-pieces).

## When ext4 features change

`tune2fs -O …` or a new `mke2fs` default changes the feature masks; the distro refuses to
boot (`ext4 features … differ from the reviewed gate`). Re-run the registration tool after
making sure the WSL kernel supports the new features.

## Updating the Linux side

Normal `apt` upgrades work from either boot. Boot-chain packages (GRUB, shim, kernels,
initramfs) are refused under WSL by `wsl-boot-packages-guard`; run those upgrades from the
native boot, where the ESP is mounted.
