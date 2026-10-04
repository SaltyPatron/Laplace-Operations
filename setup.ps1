#Requires -Version 7
<#
  The Windows machine Laplace is developed on (HART-DESKTOP), declared once and converged: the counterpart of
  setup.sh (Operations: Setup). Each part compares its declaration with the machine and acts only on what differs,
  so running it again on a finished machine changes nothing and reports. What it did is logged under
  $LAPLACE_WORK\logs\root.

    pwsh -File setup.ps1 report            what of the declarations is still on the machine; changes nothing
    pwsh -File setup.ps1 retire report     as administrator: remove what nothing uses, then report

  Policy (Laplace-Operations#2): a service never reads a person's environment; the machine environment holds only
  stable roots; no toolchain on the global PATH (oneAPI is the developer shell D:\Libraries\load-env.ps1);
  privileged steps happen here and only here.
#>
param([Parameter(Position = 0, ValueFromRemainingArguments)][string[]]$Parts = @('report'))
$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------------------------------------------ the sets
# What nothing on this machine uses any more (Laplace-Operations#7). Each row says how it is recognised and how it
# goes; a row whose thing is already gone is passed over.

# Intel oneAPI products, by the installer's own product ID and version (installer.exe --list-products).
$RetireIntel = @(
    @{ Id = 'intel.oneapi.win.basekit.product';          Ver = '2025.3.0+360'; Why = 'replaced by the oneAPI Toolkit 2026.1' }
    @{ Id = 'intel.oneapi.lin.fortran-compiler.product'; Ver = '2025.3.1+14';  Why = 'replaced by the oneAPI Toolkit 2026.1' }
)
# NVIDIA packages, by NVI2 package name (the uninstall key is {B2FE1952-0186-46C3-BAEC-A80AA35AC5B8}_<package>).
$RetireNvidia = @(
    @{ Package = 'CUDAToolkit_12.9';                 Why = 'CUDA 13.4 is installed; llama.cpp dist carries its own runtime' }
    @{ Package = 'CUDADevelopment_12.9';             Why = 'part of CUDA 12.9' }
    @{ Package = 'CUDARuntimes_12.9';                Why = 'part of CUDA 12.9' }
    @{ Package = 'CUDADocument_12.9';                Why = 'part of CUDA 12.9' }
    @{ Package = 'visual_studio_integration_12.9';   Why = 'part of CUDA 12.9' }
)
# Windows Installer products, by product code.
$RetireMsi = @(
    @{ Code = '{99EEABF5-7586-4562-B2D1-008620242D09}'; Name = 'NVIDIA Nsight Systems 2025.1.3';  Why = 'Nsight Systems 2026.3.2 is installed' }
    @{ Code = '{953EDCD3-B447-415F-9C29-AA912D38C977}'; Name = 'NVIDIA Nsight Systems 2025.6.1';  Why = 'Nsight Systems 2026.3.2 is installed' }
    @{ Code = '{8C73E5D6-6FE9-4B0A-BE67-0B7E17E7C869}'; Name = 'NVIDIA Nsight Graphics 2025.5.0'; Why = 'graphics frame debugging; not used' }
    @{ Code = '{DA08718E-972A-58E7-AE7E-C45114C82E13}'; Name = 'Java SE Development Kit 17';      Why = 'JDK 21 and 25 stay' }
    @{ Code = '{90462BD2-DF5B-449C-A401-FCC1DC264E4E}'; Name = 'Microsoft Azure Authoring Tools v2.9.7';  Why = 'classic Cloud Services, 2018' }
    @{ Code = '{04CA054C-2F40-44B0-8610-8D51EC9444FE}'; Name = 'Microsoft Azure Compute Emulator v2.9.7'; Why = 'classic Cloud Services, 2018' }
    @{ Code = '{7D1D9444-B5EA-4587-A81D-47377003124F}'; Name = 'Microsoft Azure Libraries for .NET v2.9'; Why = 'classic Cloud Services, 2018' }
    @{ Code = '{3BA7CAA9-97BA-4528-B7E1-B640910BB149}'; Name = 'Microsoft Azure PowerShell April 2018';   Why = 'superseded by Az' }
)
# Windows SDKs no longer targeted (10.0.26100.8249 stays), by their bundle's uninstall key.
$RetireSdk = @(
    @{ Key = '{5f4dc51d-f151-4325-8ba1-8b26169529a9}'; Name = 'Windows SDK 10.0.19041.5609' }
    @{ Key = '{b72d4013-dd88-405a-9f9d-e88c278dcefe}'; Name = 'Windows SDK 10.0.22621.5040' }
    @{ Key = '{b5ab6bbd-62a1-45bd-af43-2ea6ac4c3486}'; Name = 'Windows SDK 10.0.26100.7175' }
    @{ Key = '{c0b93b80-d0a4-47fc-a4d1-21a4008a63ca}'; Name = 'Windows SDK 10.0.26100.7705' }
)
# Programs with their own uninstaller, by uninstall key, in this order (PostgreSQL's add-ons before the server).
$RetireExe = @(
    @{ Key = 'PostGIS Bundle 3 for PostgreSQL x64 18'; Exe = 'C:\Program Files\PostgreSQL\18\uninstall-postgis-bundle-pg18x64-3.6.1-1.exe'; Args = @('/S');                  Why = 'PostgreSQL starts fresh (Laplace-Operations#4)' }
    @{ Key = 'pgAgent_PG18 4.2.3-1';                   Exe = 'C:\Program Files\PostgreSQL\18\uninstall-pgagent.exe';                         Args = @('--mode', 'unattended'); Why = 'PostgreSQL starts fresh' }
    @{ Key = 'PgBouncer 1.25.1-1';                     Exe = 'C:\Program Files\PgBouncer\uninstall-pgbouncer.exe';                           Args = @('--mode', 'unattended'); Why = 'PostgreSQL starts fresh' }
    @{ Key = 'psqlODBC 13.02.0000-1';                  Exe = 'C:\Program Files\PostgreSQL\psqlODBC\uninstall-psqlodbc.exe';                  Args = @('--mode', 'unattended'); Why = 'PostgreSQL starts fresh' }
    @{ Key = 'Npgsql 3.2.6-3';                         Exe = 'C:\Program Files (x86)\PostgreSQL\Npgsql\uninstall-npgsql.exe';                Args = @('--mode', 'unattended'); Why = '2017 driver' }
    @{ Key = 'PostgreSQL 18';                          Exe = 'C:\Program Files\PostgreSQL\18\uninstall-postgresql.exe';                      Args = @('--mode', 'unattended'); Why = 'PostgreSQL starts fresh' }
    @{ Key = 'Docker Desktop';                         Exe = 'C:\Program Files\Docker\Docker\Docker Desktop Installer.exe';                  Args = @('uninstall', '--quiet'); Why = 'no containers are used; its images were old oneAPI and MCP images' }
)
# Visual Studio instances, by installation path (VS 2026 and VS 2022 Community stay).
$RetireVs = @(
    @{ Path = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools'; Why = 'duplicate of VS 2022 Community, installed through chocolatey' }
)
$RetireServices = @('actions.runner.AHartTN-Hartonomous.HART-DESKTOP', 'pgagent-pg18', 'postgresql-x64-18')
$RetireTasks    = @('\Hartonomous Router Log Upload')
$RetireWsl      = @('Ubuntu', 'docker-desktop')
$RetireFeatures = @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform')
# Folders, after the programs that used them are gone.
$RetireDirs = @(
    'C:\ProgramData\chocolatey', 'D:\GitHub', 'D:\LlamaCPP', 'D:\Docker', 'D:\WSL',
    'D:\Data\Postgres', 'D:\Data\Laplace\deploy', 'D:\Data\Laplace\deps', 'D:\Data\Laplace\tools',
    'C:\Program Files\PostgreSQL', 'C:\Program Files\PgBouncer', 'C:\Program Files (x86)\PostgreSQL',
    'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\PostgreSQL 18', 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\PgBouncer',
    'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\psqlODBC',
    'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Postgres Enterprise Manager',
    'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Postgres Plus Add-ons'
)
# Machine environment values that go: blank leftovers, and values of programs that are gone.
$RetireMachineVars = @(
    'OPENSSL_CONF', 'CURL_CA_BUNDLE', 'GDAL_DATA', 'PROJ_LIB', 'POSTGIS_ENABLE_OUTDB_RASTERS', 'POSTGIS_GDAL_ENABLED_DRIVERS',
    'VS140COMNTOOLS', 'VS2022INSTALLDIR', 'IFORT_COMPILER25', 'IFORT_COMPILER26', 'ADVISOR_2025_DIR', 'VTUNE_PROFILER_2026_DIR',
    'CUDA_VISIBLE_DEVICES', 'CUDA_PATH_V12_9', 'ChocolateyInstall', 'ChocolateyLastPathUpdate', 'OLLAMA_MODELS'
)

# The machine environment Laplace's builds read: stable roots only (Laplace-Operations#2). CUDA_PATH names the newest
# CUDA toolkit installed (CUDA_PATH_V<major>_<minor>); its uninstallers remove it even when it pointed at another one.
function DeclaredMachineVars {
    $cuda = (Get-Item $MachineEnv).Property | Where-Object { $_ -match '^CUDA_PATH_V(\d+)_(\d+)$' } |
        Sort-Object { [version]($_ -replace '^CUDA_PATH_V(\d+)_(\d+)$', '$1.$2') } | Select-Object -Last 1
    $vars = [ordered]@{}
    if ($cuda) { $vars['CUDA_PATH'] = (Get-ItemProperty $MachineEnv -Name $cuda).$cuda }
    $vars
}

# ------------------------------------------------------------------------------------------------------ helpers
$UninstallKeys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
$MachineEnv = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
$work = if ($env:LAPLACE_WORK) { $env:LAPLACE_WORK } else { 'D:\Data\Laplace\work' }
$logDir = Join-Path $work 'logs\root'
New-Item -ItemType Directory -Force $logDir | Out-Null
$log = Join-Path $logDir ("setup-{0:yyyyMMddTHHmmssZ}.log" -f (Get-Date).ToUniversalTime())
Start-Transcript -Path $log | Out-Null
$failed = [System.Collections.Generic.List[string]]::new()

function Say([string]$what, [string]$state) { '  {0,-58} {1}' -f $what, $state }
function Part([string]$name) { ''; "=== $name   {0:HH:mm:ss}" -f (Get-Date).ToUniversalTime() }
function Admin { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function Installed([string]$key) { foreach ($k in $UninstallKeys) { if (Test-Path "$k\$key") { return $true } }; $false }
function Run([string]$exe, [string[]]$arguments, [int[]]$ok = @(0, 1605, 3010)) {
    $p = Start-Process -FilePath $exe -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
    if ($ok -notcontains $p.ExitCode) { throw "$exe exited $($p.ExitCode)" }
    if ($p.ExitCode -eq 3010) { $script:restart = $true }
}
function Attempt([string]$what, [scriptblock]$body) {
    try { & $body } catch { Say $what "FAILED: $($_.Exception.Message)"; $failed.Add("$what : $($_.Exception.Message)") }
}
function IntelInstalled { & 'C:\Program Files (x86)\Intel\oneAPI\Installer\installer.exe' --list-products 2>$null | Where-Object { $_ -match '\btrue\b' } | ForEach-Object { ($_ -split '\s+')[0..1] -join ' ' } }

# The dependency manifest (dependencies.tsv), this platform's rows, in file order.
$DepSrc = if ($env:LAPLACE_DEPSRC) { $env:LAPLACE_DEPSRC } else { 'D:\Libraries\src' }
$Deps   = if ($env:LAPLACE_DEPS) { $env:LAPLACE_DEPS } else { 'D:\Libraries' }
function Manifest {
    $cols = $null
    foreach ($line in Get-Content (Join-Path $PSScriptRoot 'dependencies.tsv')) {
        if (-not $line.Trim() -or $line.StartsWith('#')) { continue }
        $f = $line -split "`t"
        if (-not $cols) { $cols = $f; continue }
        $row = [ordered]@{}; for ($i = 0; $i -lt $cols.Count; $i++) { $row[$cols[$i]] = if ($i -lt $f.Count -and $f[$i] -ne '-') { $f[$i] } else { '' } }
        if (($row.platforms -split ',') -contains 'windows') { [pscustomobject]$row }
    }
}
function GitIn([string]$dir) { & git.exe -C $dir @args 2>&1 }   # not named Git: a function would shadow git.exe

# ------------------------------------------------------------------------------------------------------ the parts
# Every manifest row present at its pin. A source is a checkout at its exact commit: cloned when missing, moved to the
# pin only when its working tree is clean (local changes are reported, never reset). A release or tool is an archive,
# verified by SHA-256 before it is unpacked into its own prefix; a row without a pin is downloaded, its hash printed,
# and not used until that hash is written into the manifest.
function sources {
    Part 'sources'
    foreach ($r in Manifest) {
        $what = "$($r.name) $($r.version)"
        if ($r.kind -eq 'source') {
            Attempt $what {
                $dir = Join-Path $DepSrc $r.name
                if (-not (Test-Path (Join-Path $dir '.git'))) {
                    & git.exe clone -q --filter=blob:none --no-checkout $r.origin $dir 2>&1 | Out-Null
                    if ($LASTEXITCODE) { throw "clone failed: $($r.origin)" }
                }
                $origin = (GitIn $dir remote get-url origin | Select-Object -First 1)
                if ($origin.TrimEnd('/') -replace '\.git$' -ne ($r.origin.TrimEnd('/') -replace '\.git$')) { throw "checkout's origin is $origin, the manifest says $($r.origin)" }
                $head = (GitIn $dir rev-parse HEAD | Select-Object -First 1)
                $fresh = -not (Test-Path (Join-Path $dir '.git\index'))           # cloned, never checked out: nothing to keep
                if ($head -eq $r.pin -and -not $fresh) { Say $what "at $($r.pin.Substring(0,12))"; return }
                if (-not $fresh -and (GitIn $dir status --porcelain --untracked-files=no)) { throw "has local changes at $head; not moved to $($r.pin)" }
                GitIn $dir fetch -q origin $r.pin | Out-Null
                GitIn $dir -c advice.detachedHead=false checkout -q $r.pin | Out-Null
                if ((GitIn $dir rev-parse HEAD | Select-Object -First 1) -ne $r.pin) { throw "could not check out $($r.pin)" }
                Say $what "checked out $($r.pin.Substring(0,12))"
            }
        } elseif ($r.kind -in 'release', 'tool') {
            # unpack: an archive whose contents are the install. sfx: a self-extracting archive (MSYS2), likewise.
            # amalgamation: a source archive, unpacked in the source store for the build part. Anything else is
            # installed another way (uv tool).
            if (-not $r.origin.StartsWith('https://') -or $r.build -notin 'unpack', 'sfx', 'amalgamation') { continue }
            Attempt $what {
                $store = Join-Path (Join-Path $DepSrc $r.name) $r.version
                $prefix = if ($r.build -eq 'amalgamation') { Join-Path $store 'source' } else { Join-Path (Join-Path $Deps $r.name) $r.version }
                if (Test-Path (Join-Path $prefix '.pin')) {
                    if ((Get-Content (Join-Path $prefix '.pin') -Raw).Trim() -eq $r.pin) { Say $what "at $prefix"; return }
                    throw "$prefix holds another archive than the pin; remove it to reinstall"
                }
                New-Item -ItemType Directory -Force $store | Out-Null
                $file = Join-Path $store ([IO.Path]::GetFileName(([uri]$r.origin).AbsolutePath))
                if (-not (Test-Path $file)) { & curl.exe -fsSL --retry 3 -o $file $r.origin; if ($LASTEXITCODE) { Remove-Item $file -ErrorAction SilentlyContinue; throw "download failed: $($r.origin)" } }
                $sha = (Get-FileHash $file -Algorithm SHA256).Hash.ToLowerInvariant()
                if (-not $r.pin) { throw "no pin in dependencies.tsv; downloaded $file with SHA-256 ${sha}: review it, write the hash into the manifest, run again" }
                if ($sha -ne $r.pin) { throw "SHA-256 $sha differs from the pin $($r.pin)" }
                $stage = "$prefix.part"; Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
                if ($r.build -eq 'sfx') { Run $file @('-y', "-o$stage") @(0) }
                elseif ($file -match '\.tar\.(xz|gz|bz2)$') { New-Item -ItemType Directory -Force $stage | Out-Null; & tar.exe -xf $file -C $stage; if ($LASTEXITCODE) { throw "tar could not unpack $file" } }   # Windows' bsdtar
                else { Expand-Archive -LiteralPath $file -DestinationPath $stage }
                $inner = @(Get-ChildItem $stage); if ($inner.Count -eq 1 -and $inner[0].PSIsContainer) { $stage = $inner[0].FullName }   # one top folder: its contents are the prefix
                New-Item -ItemType Directory -Force (Split-Path $prefix) | Out-Null
                Move-Item -LiteralPath $stage -Destination $prefix
                Remove-Item "$prefix.part" -Recurse -Force -ErrorAction SilentlyContinue
                Set-Content (Join-Path $prefix '.pin') $r.pin
                Say $what "at $prefix"
            }
        }
    }
}

function retire {
    Part 'retire'
    if (-not (Admin)) { Say 'retire' 'REFUSED: run from an elevated PowerShell'; $failed.Add('retire: not elevated'); return }

    foreach ($t in $RetireTasks) {
        $task = Get-ScheduledTask | Where-Object { "$($_.TaskPath)$($_.TaskName)" -eq $t }
        if ($task) { Attempt "task $t" { $task | Unregister-ScheduledTask -Confirm:$false; Say "task $t" 'removed' } }
    }

    $intel = @(IntelInstalled)
    foreach ($r in $RetireIntel) {
        if ($intel -notcontains "$($r.Id) $($r.Ver)") { continue }
        Attempt "$($r.Id) $($r.Ver)" {
            Run 'C:\Program Files (x86)\Intel\oneAPI\Installer\installer.exe' @('-s', '--action', 'remove', '--product-id', $r.Id, '--product-ver', $r.Ver)
            Say "$($r.Id) $($r.Ver)" "removed ($($r.Why))"
        }
    }
    foreach ($r in $RetireNvidia) {
        if (-not (Installed "{B2FE1952-0186-46C3-BAEC-A80AA35AC5B8}_$($r.Package)")) { continue }
        Attempt "NVIDIA $($r.Package)" {
            Run "$env:SystemRoot\SysWOW64\RunDll32.EXE" @('"C:\Program Files\NVIDIA Corporation\Installer2\InstallerCore\NVI2.DLL",UninstallPackage', $r.Package, '-silent', '-n')
            Say "NVIDIA $($r.Package)" "removed ($($r.Why))"
        }
    }
    foreach ($r in $RetireMsi) {
        if (-not (Installed $r.Code)) { continue }
        Attempt $r.Name { Run 'msiexec.exe' @('/x', $r.Code, '/qn', '/norestart'); Say $r.Name "removed ($($r.Why))" }
    }
    foreach ($r in $RetireSdk) {
        if (-not (Installed $r.Key)) { continue }
        Attempt $r.Name {
            $setup = "C:\ProgramData\Package Cache\$($r.Key)\winsdksetup.exe"
            if (-not (Test-Path $setup)) { throw "its cached setup is missing: $setup" }
            Run $setup @('/uninstall', '/quiet', '/norestart'); Say $r.Name 'removed'
        }
    }
    foreach ($r in $RetireExe) {
        if (-not (Installed $r.Key)) { continue }
        Attempt $r.Key {
            if ((Test-Path $r.Exe) -and (Get-Item $r.Exe).Length -gt 0) { Run $r.Exe $r.Args; Say $r.Key "removed ($($r.Why))"; return }
            # A missing or empty uninstaller cannot run (HART-DESKTOP's EDB uninstallers were 0 bytes). The product's
            # services and folders are in the sets below; what remains is its registration, which goes here.
            foreach ($k in $UninstallKeys) { if (Test-Path "$k\$($r.Key)") { Remove-Item -LiteralPath "$k\$($r.Key)" -Recurse -Force } }
            Say $r.Key "uninstaller broken: registration removed; services and folders below ($($r.Why))"
        }
    }
    foreach ($r in $RetireVs) {
        if (-not (Test-Path $r.Path)) { continue }
        Attempt "Visual Studio $($r.Path)" {
            Run 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\setup.exe' @('uninstall', '--installPath', "`"$($r.Path)`"", '--quiet', '--norestart')
            Say "Visual Studio $($r.Path)" "removed ($($r.Why))"
        }
    }

    # services the uninstallers above did not take with them
    foreach ($s in $RetireServices) {
        $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
        if (-not $svc) { continue }
        Attempt "service $s" { if ($svc.Status -ne 'Stopped') { Stop-Service -Name $s -Force }; & sc.exe delete $s | Out-Null; Say "service $s" 'deleted' }
    }
    $distros = @(& wsl.exe --list --quiet 2>$null | ForEach-Object { ($_ -replace "`0", '').Trim() } | Where-Object { $_ })
    foreach ($d in $RetireWsl) { if ($distros -contains $d) { Attempt "WSL $d" { & wsl.exe --unregister $d | Out-Null; Say "WSL $d" 'unregistered' } } }
    foreach ($f in $RetireFeatures) {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction SilentlyContinue
        if ($feature -and $feature.State -eq 'Enabled') {
            Attempt "feature $f" { $r = Disable-WindowsOptionalFeature -Online -FeatureName $f -NoRestart; if ($r.RestartNeeded) { $script:restart = $true }; Say "feature $f" 'disabled' }
        }
    }

    foreach ($d in $RetireDirs) { if (Test-Path -LiteralPath $d) { Attempt $d { Remove-Item -LiteralPath $d -Recurse -Force; Say $d 'removed' } } }

    $envKey = Get-Item $MachineEnv
    foreach ($v in $RetireMachineVars) { if ($envKey.Property -contains $v) { Attempt "machine variable $v" { Remove-ItemProperty -Path $MachineEnv -Name $v; Say "machine variable $v" 'removed' } } }

    # The machine PATH keeps only entries that exist (uninstalled programs leave theirs behind), each once.
    Attempt 'machine PATH' {
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $true)
        $old = $key.GetValue('Path', '', 'DoNotExpandEnvironmentNames') -split ';' | Where-Object { $_.Trim() }
        $seen = @{}; $new = foreach ($p in $old) {
            $n = $p.Trim().TrimEnd('\').ToLowerInvariant()
            if ($seen[$n] -or -not (Test-Path ([Environment]::ExpandEnvironmentVariables($p)))) { Say "  PATH entry $p" 'dropped'; continue }
            $seen[$n] = 1; $p
        }
        if (@($new).Count -ne @($old).Count) { $key.SetValue('Path', ($new -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString) }
        $key.Close(); Say 'machine PATH' "$(@($new).Count) entries"
    }
    Add-Type -Namespace LaplaceSetup -Name Native -MemberDefinition '[DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);' -ErrorAction SilentlyContinue
    $r = [UIntPtr]::Zero; [void][LaplaceSetup.Native]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$r)
}

function environment {
    Part 'environment'
    if (-not (Admin)) { Say 'environment' 'REFUSED: run from an elevated PowerShell'; $failed.Add('environment: not elevated'); return }
    $declared = DeclaredMachineVars
    foreach ($name in $declared.Keys) {
        $have = (Get-ItemProperty $MachineEnv -Name $name -ErrorAction SilentlyContinue).$name
        if ($have -eq $declared[$name]) { Say "machine variable $name" $have; continue }
        Attempt "machine variable $name" { Set-ItemProperty -Path $MachineEnv -Name $name -Value $declared[$name]; Say "machine variable $name" "set: $($declared[$name])" }
    }
    $r = [UIntPtr]::Zero
    Add-Type -Namespace LaplaceSetup -Name Native -MemberDefinition '[DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);' -ErrorAction SilentlyContinue
    [void][LaplaceSetup.Native]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$r)
}

function report {
    Part 'report'
    $declared = DeclaredMachineVars
    foreach ($name in $declared.Keys) { $have = (Get-ItemProperty $MachineEnv -Name $name -ErrorAction SilentlyContinue).$name; Say "machine variable $name" $(if ($have -eq $declared[$name]) { $have } else { "WRONG: '$have', declared '$($declared[$name])'" }) }
    $left = [System.Collections.Generic.List[string]]::new()
    $intel = @(IntelInstalled)
    foreach ($r in $RetireIntel) { if ($intel -contains "$($r.Id) $($r.Ver)") { $left.Add("$($r.Id) $($r.Ver)") } }
    foreach ($r in $RetireNvidia) { if (Installed "{B2FE1952-0186-46C3-BAEC-A80AA35AC5B8}_$($r.Package)") { $left.Add("NVIDIA $($r.Package)") } }
    foreach ($r in $RetireMsi) { if (Installed $r.Code) { $left.Add($r.Name) } }
    foreach ($r in $RetireSdk) { if (Installed $r.Key) { $left.Add($r.Name) } }
    foreach ($r in $RetireExe) { if (Installed $r.Key) { $left.Add($r.Key) } }
    foreach ($r in $RetireVs) { if (Test-Path $r.Path) { $left.Add("Visual Studio $($r.Path)") } }
    foreach ($s in $RetireServices) { if (Get-Service -Name $s -ErrorAction SilentlyContinue) { $left.Add("service $s") } }
    foreach ($t in $RetireTasks) { if (Get-ScheduledTask | Where-Object { "$($_.TaskPath)$($_.TaskName)" -eq $t }) { $left.Add("task $t") } }
    $distros = @(& wsl.exe --list --quiet 2>$null | ForEach-Object { ($_ -replace "`0", '').Trim() } | Where-Object { $_ })
    foreach ($d in $RetireWsl) { if ($distros -contains $d) { $left.Add("WSL $d") } }
    foreach ($d in $RetireDirs) { if (Test-Path -LiteralPath $d) { $left.Add($d) } }
    $envKey = Get-Item $MachineEnv
    foreach ($v in $RetireMachineVars) { if ($envKey.Property -contains $v) { $left.Add("machine variable $v") } }
    if ($left.Count) { Say 'still present from the retire list' "$($left.Count)"; $left | ForEach-Object { "    $_" } } else { Say 'retire list' 'nothing left' }
    if (Admin) {
        foreach ($f in $RetireFeatures) { $feature = Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction SilentlyContinue; if ($feature) { Say "feature $f" $feature.State } }
    }
}

$known = 'sources', 'retire', 'environment', 'report'
foreach ($p in $Parts) { if ($known -notcontains $p) { "setup.ps1 [$($known -join '|') ...]"; Stop-Transcript | Out-Null; exit 2 } }
foreach ($p in $Parts) { & $p }
''
if ($failed.Count) { '=== failed'; $failed | ForEach-Object { "  $_" } }
if ($script:restart) { '=== a restart finishes what was removed (Windows features, installers)' }
"=== done   {0:HH:mm:ss}   $log" -f (Get-Date).ToUniversalTime()
Stop-Transcript | Out-Null
if ($failed.Count) { exit 1 }
