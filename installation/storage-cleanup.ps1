function Initialize-StorageNative {
    if (-not ('Laplace.StorageFile' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace Laplace {
 public static class StorageFile {
  [StructLayout(LayoutKind.Sequential)] struct Information {
   public uint attributes;
   public System.Runtime.InteropServices.ComTypes.FILETIME created,accessed,written;
   public uint volume,sizeHigh,sizeLow,links,indexHigh,indexLow;
  }
  [DllImport("kernel32.dll",SetLastError=true)]
  static extern bool GetFileInformationByHandle(SafeFileHandle handle,out Information information);
  [DllImport("shell32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
  static extern IntPtr CommandLineToArgvW(string command,out int count);
  [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr pointer);
  public static string[] Arguments(string command) {
   int count;var pointer=CommandLineToArgvW(command,out count);
   if(pointer==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error());
   try {
    var result=new string[count];
    for(int i=0;i<count;i++)result[i]=Marshal.PtrToStringUni(Marshal.ReadIntPtr(pointer,i*IntPtr.Size));
    return result;
   } finally {LocalFree(pointer);}
  }
  public static uint Links(string path) {
   using(var handle=File.OpenHandle(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete)) {
    Information info;
    if(!GetFileInformationByHandle(handle,out info))throw new Win32Exception(Marshal.GetLastWin32Error());
    return info.links;
   }
  }
 }
}
'@
    }
}

function Get-StorageLinkCount([string]$Path) {
    Initialize-StorageNative
    return [Laplace.StorageFile]::Links($Path)
}

function Initialize-PerfCacheShards {
    param([string]$PreparedDirectory, [string]$BinDirectory)
    if (-not $PreparedDirectory -or -not (Test-Path -LiteralPath $PreparedDirectory -PathType Container)) { return }
    $tier0Path = Join-Path $PreparedDirectory 'tier0.bin'
    $flagsPath = Join-Path $PreparedDirectory 'tier0.flags'
    if (-not (Test-Path -LiteralPath $tier0Path -PathType Leaf)) { return }
    $tier0Exe = if ($BinDirectory) { Join-Path $BinDirectory 'laplace-tier0.exe' } else { $null }
    $laplaceExe = if ($BinDirectory) { Join-Path $BinDirectory 'laplace.exe' } else { $null }
    if ($tier0Exe -and (Test-Path -LiteralPath $tier0Exe -PathType Leaf)) {
        & $tier0Exe --shards -o $tier0Path 2>$null | Out-Null
    } elseif ($laplaceExe -and (Test-Path -LiteralPath $laplaceExe -PathType Leaf)) {
        & $laplaceExe tier0 --shards -o $tier0Path 2>$null | Out-Null
        if (Test-Path -LiteralPath $flagsPath -PathType Leaf) {
            & $laplaceExe flags --shards -o $flagsPath 2>$null | Out-Null
        }
    }
}

function Test-StoragePublisher($Process) {
    if(-not $Process.command){return $false}
    Initialize-StorageNative
    $arguments=[Laplace.StorageFile]::Arguments($Process.command)
    $scripts=@('package-windows-client.py','windows-components.py','Build-IisPackage.ps1','Publish-IisRuntime.ps1','Deploy-Desktop.ps1','install-windows-client.ps1','setup-iis.ps1','desktop-uci.ps1')
    if($Process.name -in @('pwsh.exe','powershell.exe')) {
        for($i=1;$i -lt $arguments.Length;$i++) {
            if($arguments[$i] -in @('-Command','-c','-EncodedCommand','-ec','-e')){return $false}
            if($arguments[$i] -in @('-File','-f') -and $i+1 -lt $arguments.Length) {
                return [IO.Path]::GetFileName($arguments[$i+1]) -in $scripts
            }
            if($arguments[$i] -like '*.ps1'){return [IO.Path]::GetFileName($arguments[$i]) -in $scripts}
        }
    } elseif($Process.name -match '^(?:python[\d.]*|py)\.exe$') {
        for($i=1;$i -lt $arguments.Length;$i++) {
            if($arguments[$i] -in @('-c','-m')){return $false}
            if($arguments[$i] -like '*.py'){return [IO.Path]::GetFileName($arguments[$i]) -in $scripts}
        }
    }
    return $false
}

function Assert-StorageTree([string]$Path, [string]$Root) {
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    $target = [IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    if ([IO.Path]::GetDirectoryName($target) -ine $rootPath) { throw "Retirement escaped its owning directory: $target" }
    $ancestors = @((Get-Item -LiteralPath $target))
    for ($ancestor = Get-Item -LiteralPath $rootPath; $null -ne $ancestor; $ancestor = $ancestor.Parent) { $ancestors += $ancestor }
    foreach ($item in $ancestors) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Retirement may not traverse a reparse point: $($item.FullName)" }
    }
    foreach ($item in Get-ChildItem -LiteralPath $target -Recurse -Force) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Retirement contains a reparse point: $($item.FullName)" }
    }
}

function Invoke-StorageDatabaseCleanup {
    $databaseOutput=& py -3 "$PSScriptRoot/database-storage.py" --windows-config "$PSScriptRoot/hart-desktop-operator.json"
    if($LASTEXITCODE){throw 'Native stage cleanup failed; inspect the database error above.'}
    return @(($databaseOutput -join "`n") | ConvertFrom-Json)
}

function Remove-StorageEntry($Entry) {
    Assert-StorageTree $Entry.path $Entry.root
    if($Entry.uci_payload_sha256 -and (Get-StorageUciPayload $Entry.path) -cne $Entry.uci_payload_sha256){throw "UCI payload changed during retention: $($Entry.path)"}
    if($Entry.kind -eq 'operation_history' -and (Test-Path -LiteralPath $Entry.path -PathType Container)) {
        if((Test-Path -LiteralPath (Join-Path $Entry.path '.retain')) -or
            @(Get-ChildItem -LiteralPath $Entry.path -Recurse -Force -Filter '.git').Count) {
            throw "Operation became protected during retention: $($Entry.path)"
        }
    }
    if($Entry.marker -and -not (Read-StorageJson (Join-Path $Entry.path $Entry.marker))){throw "Retirement marker changed: $($Entry.path)"}
    if($Entry.receipt_sha256 -and (Get-FileHash -LiteralPath $Entry.receipt_path -Algorithm SHA256).Hash -ne $Entry.receipt_sha256) {
        throw "Operation receipt changed during retention: $($Entry.path)"
    }
    Remove-Item -LiteralPath $Entry.path -Recurse -Force -ErrorAction Stop
}

function Invoke-OperationHistoryCleanup {
    param([string]$WorkRoot=$env:LAPLACE_WORK,[object[]]$Processes)
    $operation=Enter-DesktopStorageOperation $WorkRoot -IfIdle
    if($operation -is [bool] -and -not $operation){return}
    $plan=@{schema='laplace.operation-history/v1';status='failed';entries=@();removed=@()}
    try {
        $root=Join-Path $WorkRoot 'operations'
        if(-not $PSBoundParameters.ContainsKey('Processes')){$Processes=@(Get-StorageProcesses)}
        $plan.entries=@(Get-StorageOperationHistory -Root $root -Processes $Processes -References @())
        foreach($entry in $plan.entries|Where-Object retire){Remove-StorageEntry $entry;$plan.removed+=$entry.path}
        $plan.status='passed'
    } catch {$plan.error=$_.Exception.Message;throw}
    finally {
        try {if($plan.removed.Count -or $plan.error) {
            $receipt=Join-Path $root ('storage-'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ')+'.json')
            $plan.finished_utc=[DateTime]::UtcNow.ToString('o');$plan.receipt=$receipt
            $plan|ConvertTo-Json -Depth 9|Set-Content -LiteralPath $receipt
            Write-Host "History cleanup: $($plan.removed.Count) superseded runs removed. Receipt: $receipt"
        }} finally {Close-DesktopStorageOperation $operation}
    }
}

function Invoke-DesktopStorageCleanup {
    param([Parameter(Mandatory)][string]$WorkRoot,[Parameter(Mandatory)][string]$BuildRoot,
          [Parameter(Mandatory)]$Modular,[Parameter(Mandatory)]$Iis,
          [ValidateRange(0,10)][int]$Rollback=1,[object[]]$Processes,[string[]]$DatabaseReferences,[string[]]$BuildReferences)
    $locks = @()
    $operation=Enter-DesktopStorageOperation $WorkRoot
    $plan = $null
    $removed = @()
    $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($WorkRoot)))
    $freeBefore = $drive.AvailableFreeSpace
    $drives=@(@($WorkRoot,$BuildRoot,$Modular.prefix,$Modular.artifacts,$Iis.directory) |
        ForEach-Object { [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($_)) } | Select-Object -Unique |
        ForEach-Object { @{drive=$_;free_bytes_before=([IO.DriveInfo]::new($_)).AvailableFreeSpace} })
    try {
        # The existing publication/component locks prevent a candidate from
        # becoming installed while its retirement plan is being applied.
        $publicationLocks=@((Join-Path $Iis.directory 'web/.publication.lock'),(Join-Path $Modular.artifacts '.build.lock'))
        $uci=Get-StorageUciInstallation $Iis
        if($uci){$publicationLocks+=Join-Path $uci.root '.publication.lock'}
        foreach ($path in $publicationLocks) {
            $locks += [IO.File]::Open($path,'OpenOrCreate','ReadWrite','None')
        }
        $processes = if ($PSBoundParameters.ContainsKey('Processes')) { $Processes } else { @(Get-StorageProcesses) }
        $ancestors=Get-StorageAncestorIds
        if (@($processes | Where-Object {-not $ancestors.Contains([int]$_.pid) -and (Test-StoragePublisher $_)}).Count) {
            throw 'A desktop publisher is active; storage was not changed.'
        }
        $references = if ($PSBoundParameters.ContainsKey('DatabaseReferences')) { $DatabaseReferences } else { @(Get-StorageDatabaseReferences) }
        $buildReferences = if ($PSBoundParameters.ContainsKey('BuildReferences')) { $BuildReferences } else { @(Get-StorageBuildReferences $BuildRoot) }
        $plan = Get-DesktopStoragePlan -WorkRoot $WorkRoot -BuildRoot $BuildRoot -Modular $Modular -Iis $Iis -Processes $processes -Rollback $Rollback -DatabaseReferences $references -BuildReferences $buildReferences
        $plan.database_cleanup=@(Invoke-StorageDatabaseCleanup)
        foreach ($entry in $plan.entries | Where-Object retire) {
            Remove-StorageEntry $entry
            $removed += $entry.path
        }
        # Shared files survive while any retained release or component links
        # them. Only blobs with no other directory entry are collected.
        $blobs = Join-Path $Modular.artifacts 'blobs'
        if (Test-Path -LiteralPath $blobs) {
            for ($ancestor=Get-Item -LiteralPath $blobs; $null -ne $ancestor; $ancestor=$ancestor.Parent) {
                if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Blob collection may not traverse a reparse point: $($ancestor.FullName)" }
            }
            foreach ($bucket in Get-ChildItem -LiteralPath $blobs -Directory) {
                if ($bucket.Name -notmatch '^[a-f0-9]{2}$' -or $bucket.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                foreach ($blob in Get-ChildItem -LiteralPath $bucket.FullName -File) {
                    if ($blob.Name -notmatch '^[a-f0-9]{64}$' -or $blob.Name.Substring(0,2) -ne $bucket.Name -or
                        $blob.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                    if ((Get-StorageLinkCount $blob.FullName) -eq 1 -and -not (Test-StorageReference $blob.FullName $references $processes)) {
                        Remove-Item -LiteralPath $blob.FullName -Force -ErrorAction Stop
                        $removed += $blob.FullName
                    }
                }
            }
        }
        $plan.status = 'passed'
        return $plan
    } catch {
        if ($plan) { $plan.status='failed'; $plan.error=$_.Exception.Message }
        throw
    } finally {
        try {
        if ($plan) {
            $plan.removed = $removed
            $plan.free_bytes_before = $freeBefore
            $plan.free_bytes_after = $drive.AvailableFreeSpace
            foreach($volume in $drives){$volume.free_bytes_after=([IO.DriveInfo]::new($volume.drive)).AvailableFreeSpace}
            $plan.drives=$drives
            $plan.finished_utc = [DateTime]::UtcNow.ToString('o')
            $receipt = Join-Path $WorkRoot ('operations/storage-'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ')+'.json')
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $receipt) -Force
            $plan.receipt = $receipt
            $plan | ConvertTo-Json -Depth 9 | Set-Content -LiteralPath $receipt
        }
        } finally {
            foreach ($lock in $locks) { $lock.Dispose() }
            Close-DesktopStorageOperation $operation
        }
    }
}
