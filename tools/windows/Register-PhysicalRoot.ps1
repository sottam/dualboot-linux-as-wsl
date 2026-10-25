<#
.SYNOPSIS
    Register an existing Linux root partition on a physical disk as a WSL 2 distro
    for the patched WSL service in this repository.

.DESCRIPTION
    Reads the identity of the disk (through the same IOCTL the patched service uses) and of
    the partition, reads the ext4 superblock directly from the disk, checks the on-disk ext4
    features against the source of the installed stock WSL kernel, and then (only with
    -Apply) writes:

      HKLM\SOFTWARE\X1Unified\PhysicalRoots\{distro-guid}   authorization read by the
                                                           patched service
      HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss\{distro-guid}
                                                           regular distro registration

    Without -Apply nothing is written. Run from an elevated PowerShell: reading the raw
    disk and writing HKLM require administrator rights. Prepare the root from the native
    boot first (docs/install.md, step 1): this tool refuses a filesystem that was not
    shut down cleanly.

    Re-run with the same -DistroName after a WSL kernel update or after ext4 features
    change; the patched mini_init refuses to boot until the authorization matches.

.EXAMPLE
    Get-Disk; Get-Partition -DiskNumber 1
    .\Register-PhysicalRoot.ps1 -DiskNumber 1 -PartitionNumber 2 -DistroName MyLinux
    .\Register-PhysicalRoot.ps1 -DiskNumber 1 -PartitionNumber 2 -DistroName MyLinux -Apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][int]$DiskNumber,
    [Parameter(Mandatory)][int]$PartitionNumber,
    [string]$DistroName = 'PhysicalLinux',
    [int]$DefaultUid = 0,
    [string]$BasePath,
    [switch]$Apply,
    [switch]$SkipKernelSourceCheck
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$LinuxFilesystemType = '{0fc63daf-8483-4772-8e79-3d69d8477de4}'
$RegistryRoot = 'HKLM:\SOFTWARE\X1Unified\PhysicalRoots'   # path read by the patched service
$LxssRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
# Runtime state left by an unclean shutdown, not features: never authorize them.
$IncompatRecover = 0x4
$RoCompatOrphanPresent = 0x10000

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run from an elevated PowerShell (raw disk read and HKLM write).'
}
if ($DistroName -notmatch '^[A-Za-z0-9._-]{1,64}$') { throw 'DistroName: use 1-64 letters, digits, ".", "_" or "-".' }

# --- Disk identity, read exactly as the patched service reads it -----------------------
# The service compares STORAGE_DEVICE_DESCRIPTOR ProductId and SerialNumber, trimmed of
# spaces. Get-Disk FriendlyName is shown for humans only.
if (-not ('PhysicalRootIdentity' -as [type])) {
    Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Text; using Microsoft.Win32.SafeHandles;
public static class PhysicalRootIdentity {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(SafeFileHandle h, uint code, byte[] inBuf, int inSize, byte[] outBuf, int outSize, out int returned, IntPtr overlapped);
    static string Field(byte[] b, int size, int offset) {
        if (offset == 0 || offset >= size) return "";
        int end = offset; while (end < size && b[end] != 0) end++;
        return Encoding.ASCII.GetString(b, offset, end - offset).Trim(' ');
    }
    public static string[] Query(int disk) {
        using (var h = CreateFileW("\\\\.\\PhysicalDrive" + disk, 0, 3, IntPtr.Zero, 3, 0, IntPtr.Zero)) {
            if (h.IsInvalid) throw new System.ComponentModel.Win32Exception();
            var query = new byte[12]; var output = new byte[4096]; int size;
            if (!DeviceIoControl(h, 0x2D1400, query, query.Length, output, output.Length, out size, IntPtr.Zero))
                throw new System.ComponentModel.Win32Exception();
            return new[] { Field(output, size, BitConverter.ToInt32(output, 16)), Field(output, size, BitConverter.ToInt32(output, 24)) };
        }
    }
}
'@
}
$disk = Get-Disk -Number $DiskNumber
if ($disk.IsBoot -or $disk.IsSystem) { throw "Disk $DiskNumber is a Windows boot/system disk; refusing." }
if ($disk.PartitionStyle -ne 'GPT') { throw "Disk $DiskNumber is not GPT." }
$model, $serial = [PhysicalRootIdentity]::Query($DiskNumber)
if (-not $model -or -not $serial) { throw "Disk $DiskNumber does not report a model and serial number." }
$sameIdentity = @(Get-Disk | Where-Object {
    try { $m, $s = [PhysicalRootIdentity]::Query($_.Number); $m -ceq $model -and $s -ceq $serial } catch { $true }
})
if ($sameIdentity.Count -ne 1) { throw 'Model and serial do not identify exactly one disk (or a disk could not be inspected).' }
$partition = Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue | Where-Object PartitionNumber -eq $PartitionNumber
if (-not $partition) { throw "Disk $DiskNumber has no partition $PartitionNumber (see Get-Partition -DiskNumber $DiskNumber)." }
if ($partition.GptType -ne $LinuxFilesystemType) {
    throw "Partition $PartitionNumber has GPT type $($partition.GptType); only the generic Linux filesystem type is supported."
}
$lettered = @(Get-Partition -DiskNumber $DiskNumber | Where-Object { $_.DriveLetter })
if ($lettered.Count) { Write-Warning "Disk $DiskNumber has Windows drive letters ($($lettered.DriveLetter -join ', ')); WSL takes the whole disk offline while the distro runs." }

# --- ext4 superblock, read from the raw disk (sector-aligned) ---------------------------
$stream = [IO.File]::Open("\\.\PhysicalDrive$DiskNumber", 'Open', 'Read', 'ReadWrite')
try {
    $buffer = New-Object byte[] 4096
    $stream.Position = $partition.Offset
    if ($stream.Read($buffer, 0, 4096) -ne 4096) { throw 'Short read of the superblock.' }
} finally { $stream.Dispose() }
$sb = $buffer[1024..2047]
function U16([int]$o) { [BitConverter]::ToUInt16($sb, $o) }
function U32([int]$o) { [BitConverter]::ToUInt32($sb, $o) }
if ((U16 0x38) -ne 0xEF53) { throw 'Partition does not contain an ext4 superblock (LUKS, LVM, btrfs, xfs are not supported).' }
$uuid = -join ($sb[0x68..0x77] | ForEach-Object { $_.ToString('x2') })
$compat = U32 0x5C; $incompat = U32 0x60; $roCompat = U32 0x64
$clean = ((U16 0x3A) -band 1) -eq 1
if (($incompat -band $IncompatRecover) -or ($roCompat -band $RoCompatOrphanPresent) -or -not $clean) {
    throw 'The filesystem was not shut down cleanly (journal recovery pending, or the native system is hibernated). Boot the native system, disable hibernation, shut down fully, then re-run.'
}

# --- WSL kernel: only the stock kernel of the installed package is supported ---------------
$wslconfig = Join-Path $env:USERPROFILE '.wslconfig'
if ((Test-Path $wslconfig) -and (Select-String -Path $wslconfig -Pattern '^\s*kernel\s*=' -Quiet)) {
    throw "$wslconfig sets a custom kernel; the gate supports only the stock WSL kernel."
}
$kernelBinary = Join-Path $env:ProgramFiles 'WSL\tools\kernel'
$match = [regex]::Match([Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($kernelBinary)), '(\d+\.\d+\.\d+\.\d+)-microsoft-standard-WSL2')
if (-not $match.Success) { throw "Cannot find the kernel release in $kernelBinary." }
$kernelRelease = $match.Value
$tag = "linux-msft-wsl-$($match.Groups[1].Value)"

if (-not $SkipKernelSourceCheck) {
    $ext4h = (Invoke-WebRequest -UseBasicParsing "https://raw.githubusercontent.com/microsoft/WSL2-Linux-Kernel/$tag/fs/ext4/ext4.h").Content
    $text = [regex]::Replace($ext4h, '/\*.*?\*/', '', 'Singleline').Replace("\`n", ' ')
    function Resolve-Macro([string]$name, [int]$depth = 0) {
        if ($depth -gt 16) { throw "Recursive macro $name" }
        $m = [regex]::Match($text, "(?m)^#define\s+$([regex]::Escape($name))[ \t]+([^\n]+)")
        if (-not $m.Success) { throw "Macro $name not found in $tag ext4.h" }
        $value = 0L
        foreach ($term in ($m.Groups[1].Value -replace '[()\s]', '' -split '\|')) {
            if ($term -match '^0x[0-9a-fA-F]+$') { $value = $value -bor [Convert]::ToInt64($term, 16) }
            elseif ($term -match '^\d+$') { $value = $value -bor [int64]$term }
            elseif ($term -match '^[A-Z0-9_]+$') { $value = $value -bor (Resolve-Macro $term ($depth + 1)) }
            else { throw "Unreviewed macro expression in $name" }
        }
        return $value
    }
    $incompatSupp = Resolve-Macro 'EXT4_FEATURE_INCOMPAT_SUPP'
    $roCompatSupp = Resolve-Macro 'EXT4_FEATURE_RO_COMPAT_SUPP'
    if ($incompat -band (-bnot $incompatSupp)) { throw ("INCOMPAT features 0x{0:x} are not supported by {1}" -f ($incompat -band (-bnot $incompatSupp)), $tag) }
    if ($roCompat -band (-bnot $roCompatSupp)) { throw ("RO_COMPAT features 0x{0:x} are not supported for read-write by {1}" -f ($roCompat -band (-bnot $roCompatSupp)), $tag) }
    $kernelCheck = "all INCOMPAT and RO_COMPAT bits supported by $tag"
} else { $kernelCheck = 'SKIPPED' }

# --- Registration: never reuse a VHD distro, never share a metadata directory -------------
$sameName = @(Get-ChildItem $LxssRoot -ErrorAction SilentlyContinue | Where-Object {
    $n = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).DistributionName; $n -and $n -ieq $DistroName })
if ($sameName.Count -gt 1) { throw "More than one distro is named $DistroName." }
$guid = $null
if ($sameName.Count -eq 1) {
    $guid = $sameName[0].PSChildName
    if (-not (Test-Path (Join-Path $RegistryRoot $guid))) {
        throw "A regular (VHD) distro named '$DistroName' already exists; choose another name. Reusing it could later delete its VHD."
    }
    $BasePath = (Get-ItemProperty $sameName[0].PSPath).BasePath
} else {
    $guid = '{' + [guid]::NewGuid().ToString() + '}'
    if (-not $BasePath) { $BasePath = Join-Path $env:LOCALAPPDATA "PhysicalRootDistros\$DistroName" }
    if ((Test-Path $BasePath) -and @(Get-ChildItem -Force $BasePath).Count) { throw "BasePath $BasePath exists and is not empty; use a new, dedicated directory." }
    $used = @(Get-ChildItem $LxssRoot -ErrorAction SilentlyContinue | Where-Object { (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).BasePath -ieq $BasePath })
    if ($used.Count) { throw "BasePath $BasePath is used by another distro." }
}
$otherAuth = @(Get-ChildItem $RegistryRoot -ErrorAction SilentlyContinue | Where-Object {
    $_.PSChildName -ne $guid -and (Get-ItemProperty $_.PSPath).PartitionGuid -ieq $partition.Guid })
if ($otherAuth.Count) { Write-Warning "Another registration ($($otherAuth.PSChildName -join ', ')) is authorized for the same partition; only one can run at a time." }

$authorization = [ordered]@{
    Model = $model; Serial = $serial; PartitionGuid = $partition.Guid
    Ext4Uuid = $uuid; UserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    KernelRelease = $kernelRelease
}
$masks = [ordered]@{ Ext4Compat = [int]$compat; Ext4Incompat = [int]$incompat; Ext4RoCompat = [int]$roCompat }

"Distro         : $DistroName $guid $(if ($sameName.Count) { '(existing physical registration)' } else { '(new)' })"
"Disk           : $DiskNumber  $($disk.FriendlyName)  $([math]::Round($disk.Size/1GB)) GB"
"Partition      : $PartitionNumber  PARTUUID $($partition.Guid)  $([math]::Round($partition.Size/1GB)) GB"
"ext4           : UUID $uuid  compat 0x$($compat.ToString('x8')) incompat 0x$($incompat.ToString('x8')) ro_compat 0x$($roCompat.ToString('x8'))  state clean"
"Kernel         : $kernelRelease  ($kernelCheck)"
"BasePath       : $BasePath"
if (-not $Apply) { 'Dry run: nothing written. Re-run with -Apply to register.'; return }

$key = Join-Path $RegistryRoot $guid
New-Item -Path $key -Force | Out-Null
$authorization.GetEnumerator() | ForEach-Object { New-ItemProperty -Path $key -Name $_.Key -Value $_.Value -PropertyType String -Force | Out-Null }
$masks.GetEnumerator() | ForEach-Object { New-ItemProperty -Path $key -Name $_.Key -Value $_.Value -PropertyType DWord -Force | Out-Null }

if (-not $sameName.Count) {
    New-Item -ItemType Directory -Force $BasePath | Out-Null
    $distroKey = Join-Path $LxssRoot $guid
    New-Item -Path $distroKey -Force | Out-Null
    New-ItemProperty -Path $distroKey -Name DistributionName -Value $DistroName -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $distroKey -Name BasePath -Value $BasePath -PropertyType String -Force | Out-Null
    @{ Version = 2; State = 1; Flags = 15; DefaultUid = $DefaultUid }.GetEnumerator() | ForEach-Object {
        New-ItemProperty -Path $distroKey -Name $_.Key -Value $_.Value -PropertyType DWord -Force | Out-Null
    }
}
"Registered. Start it with: wsl -d $DistroName"
