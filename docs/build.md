# Building the patched WSL

The build produces `wsl.msi` (x64), the same package format as the official release.
It needs Windows, Visual Studio 2022 and a lot of RAM: on a 16 GB laptop the build
repeatedly ran out of memory; a 64 GB desktop builds it in ~7 minutes clean, ~1 minute
incremental. Building on another Windows machine and copying the MSI works fine.

## Prerequisites

- Visual Studio 2022 (Community is fine) with these components. The upstream `.vsconfig`
  asks for `Microsoft.VisualStudio.Component.VC.Tools.x86.x64.Spectre`, an ID that does not
  exist in VS 17.14, so the Spectre libraries are silently skipped and the build fails
  later with `MSB8040`. Use:

  ```json
  {
    "version": "1.0",
    "components": [
      "Microsoft.Component.MSBuild",
      "Microsoft.VisualStudio.Component.VC.CoreIde",
      "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
      "Microsoft.VisualStudio.Component.VC.Runtimes.x86.x64.Spectre",
      "Microsoft.VisualStudio.Component.VC.ATL",
      "Microsoft.VisualStudio.Component.VC.ATL.Spectre",
      "Microsoft.VisualStudio.Component.VC.Llvm.Clang",
      "Microsoft.VisualStudio.Component.Windows11SDK.26100",
      "Microsoft.VisualStudio.Workload.ManagedDesktop",
      "Microsoft.VisualStudio.Workload.Universal",
      "Microsoft.VisualStudio.Workload.NativeDesktop"
    ]
  }
  ```

- CMake ≥ 3.25 (CMake 4.4 works; the VS-bundled 3.31 also works).
- Developer Mode on (the configure step creates symlinks), or an elevated shell.
- ~25 GB free: ~5 GB of NuGet packages in the tree plus build output.

Do **not** delete `C:\ProgramData\Microsoft\VisualStudio\Packages` to save space: it also
holds `_Instances`, the installer's registration of your VS install.

## Build

```powershell
git clone --branch 3.0.3 https://github.com/microsoft/WSL.git
cd WSL
git am @((Get-ChildItem path\to\dualboot-linux-as-wsl\patches\*.patch | Sort-Object Name).FullName)
if ($LASTEXITCODE) { throw 'git am failed' }
cmake . -DCMAKE_BUILD_TYPE=Release
cmake --build . --config Release --target msipackage -- /m
# result: bin\x64\Release\wsl.msi
```

On a low-memory machine use `/m:2` or `/m:1`. If an incremental build fails with
`LNK1103: debugging information corrupt` (the shared precompiled-header PDB changed),
run `cmake --build . --config Release --target clean` and build again.

## Verify what you built

- `wsl --version` after installing shows the commit of your tree.
- The kernel shipped in the MSI comes from the `Microsoft.WSL.Kernel` NuGet package
  (unsigned). It can be compared byte for byte with the kernel inside the
  Authenticode-signed official MSI of the same version, extracted without installing:
  `msiexec /a wsl.3.0.3.0.x64.msi /qn TARGETDIR=C:\tmp\wsl-official` →
  `PFiles64\WSL\tools\kernel`.

## Install and roll back

```powershell
wsl --shutdown
msiexec /i bin\x64\Release\wsl.msi /qn /norestart /l*v install.log
```

The MSI upgrades the official one (same UpgradeCode). Keep the official MSI of your
current version from the [WSL releases](https://github.com/microsoft/WSL/releases) to
roll back: `msiexec /x` the product, then `msiexec /i` the official MSI.
