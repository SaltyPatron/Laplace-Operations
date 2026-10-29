#Requires -Version 7
. "$PSScriptRoot/../secrets/process.ps1"

function Read-DevelopmentConfig([string]$Installation) {
    $c = Get-Content -LiteralPath $Installation -Raw | ConvertFrom-Json
    if (-not $env:LAPLACE_DEVELOPMENT_INSTALLATION -and $c.PSObject.Properties['authentication'] -and $c.authentication -eq 'sspi' -and $c.database_host -ine $env:COMPUTERNAME) {
        . "$PSScriptRoot/../laplace.env.ps1"
        $hostLower = $env:COMPUTERNAME.ToLowerInvariant()
        $c.client = $hostLower
        $c.bao_role = "laplace-$hostLower-development"
        $c.identity_reference = "kv/hosts/$hostLower/laplace-mono-identity"
        $c.database_host = $env:COMPUTERNAME
        $c.port = [int]$env:LAPLACE_PGPORT
        $c.psql = (Join-Path $env:LAPLACE_PG_DIR 'bin/psql.exe') -replace '\\', '/'
        $c.admin_role = $env:USERNAME
        $c.root_certificate = (Join-Path $env:LOCALAPPDATA "Laplace/pgadmin/$hostLower-postgresql.crt") -replace '\\', '/'
        $c.windows_identities = @("$env:COMPUTERNAME\$env:USERNAME", "IIS APPPOOL\laplace-mono")
        if($c.uci){$c.windows_identities+=('IIS APPPOOL\'+$c.uci.service)}
    }
    $c
}

function Initialize-DevelopmentKeyRing {
    param([string]$DataRoot=$env:LAPLACE_DATA_ROOT,[string]$WorkRoot=$env:LAPLACE_WORK,
          [string]$IisInstallation=$env:LAPLACE_IIS_INSTALLATION)
    foreach($path in $DataRoot,$WorkRoot){
        if(-not [IO.Path]::IsPathFullyQualified($path)){throw 'Development data and work roots must be absolute.'}
    }
    $service=Join-Path $DataRoot 'services/laplace-mono-api'
    if($IisInstallation -and (Test-Path -LiteralPath $IisInstallation)){
        $installed=Get-Content -LiteralPath $IisInstallation -Raw|ConvertFrom-Json
        if(-not [IO.Path]::IsPathFullyQualified([string]$installed.directory)){throw 'The IIS service directory must be absolute.'}
        $service=$installed.directory
    }
    $destination=[IO.Path]::GetFullPath((Join-Path $service 'state/keys'))
    $work=[IO.Path]::GetFullPath($WorkRoot).TrimEnd('\','/')
    if($destination -ieq $work -or $destination.StartsWith($work+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){
        throw 'Persistent development keys must be outside the disposable work root.'
    }
    $legacy=Join-Path $work 'development/keys'
    foreach($path in $destination,$legacy){
        for($itemPath=$path;$itemPath;$itemPath=[IO.Path]::GetDirectoryName($itemPath)){
            if((Test-Path -LiteralPath $itemPath) -and ((Get-Item -LiteralPath $itemPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){
                throw "Key-ring migration cannot traverse a reparse point: $itemPath"
            }
        }
    }
    $files=if(Test-Path -LiteralPath $legacy -PathType Container){@(Get-ChildItem -LiteralPath $legacy -Filter '*.xml' -File)}else{@()}
    # Preflight the entire merge: never replace a serving key or partially
    # accept an inconsistent key ID. Preserve revocation XML alongside keys.
    foreach($file in $files){
        $target=Join-Path $destination $file.Name
        if(($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            ((Test-Path -LiteralPath $target) -and ((Get-Item -LiteralPath $target -Force).Attributes -band [IO.FileAttributes]::ReparsePoint))){throw 'Key-ring files must not be reparse points.'}
        if((Test-Path -LiteralPath $target) -and (Get-FileHash -LiteralPath $target).Hash -ne (Get-FileHash -LiteralPath $file.FullName).Hash){
            throw "Conflicting persistent key-ring file: $($file.Name)"
        }
    }
    $null=New-Item -ItemType Directory -Path $destination -Force
    foreach($file in $files){
        $target=Join-Path $destination $file.Name
        if(-not (Test-Path -LiteralPath $target)){[IO.File]::Copy($file.FullName,$target,$false)}
        if((Get-FileHash -LiteralPath $target).Hash -ne (Get-FileHash -LiteralPath $file.FullName).Hash){throw "Key-ring copy verification failed: $($file.Name)"}
    }
    return $destination
}

function Get-DevelopmentCredentialPath($Config) {
    if ($Config.client -notmatch '^[a-z][a-z0-9-]*$') { throw 'Invalid development client name.' }
    if ($env:LAPLACE_DEVELOPMENT_CREDENTIALS) {
        if (-not [IO.Path]::IsPathFullyQualified($env:LAPLACE_DEVELOPMENT_CREDENTIALS)) { throw 'LAPLACE_DEVELOPMENT_CREDENTIALS must be absolute.' }
        return $env:LAPLACE_DEVELOPMENT_CREDENTIALS
    }
    Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) "Laplace/credentials/$($Config.client).json"
}

function Get-DevelopmentBaoAddress($Config) {
    $address = [Uri]$Config.bao_address
    if (-not $address.IsAbsoluteUri -or $address.Scheme -ne 'https' -or $address.UserInfo -or $address.Query -or $address.Fragment -or $address.AbsolutePath -ne '/') {
        throw 'The development Bao address must be an HTTPS origin.'
    }
    $address.AbsoluteUri.TrimEnd('/')
}

function Get-DevelopmentSecretPaths($Config) {
    $null = Get-DevelopmentCredentialPath $Config
    if ($Config.identity_reference -notmatch '^kv/[a-zA-Z0-9_/-]+$' -or $Config.identity_reference -match '//|/\.\.?(/|$)') { throw 'Invalid shared identity record.' }
    $paths=[ordered]@{
        'laplace-api' = "kv/hosts/$($Config.client)/laplace-api"
        identity = $Config.identity_reference
    }
    if(-not $Config.PSObject.Properties['authentication'] -or $Config.authentication -ne 'sspi'){
        $paths.substrate="kv/hosts/$($Config.client)/substrate"
        $paths.appdb="kv/hosts/$($Config.client)/appdb"
    }
    $paths
}

function Read-DevelopmentEnrollment($Config) {
    if (-not $IsWindows) { throw 'Desktop enrollment uses Windows user-bound DPAPI.' }
    $path = Get-DevelopmentCredentialPath $Config
    $secure = $null
    try {
        $ciphertext = Get-Content -LiteralPath $path -Raw
        $secure = ConvertTo-SecureString $ciphertext.Trim() -ErrorAction Stop
        $enrollment = ([Net.NetworkCredential]::new('', $secure)).Password | ConvertFrom-Json
    } catch { throw "Cannot decrypt the desktop enrollment for this Windows user: $path" }
    finally { if ($secure) { $secure.Dispose() } }
    if ($enrollment.version -ne 1 -or $enrollment.client -ne $Config.client -or $enrollment.role -ne $Config.bao_role -or
        $enrollment.address -ne (Get-DevelopmentBaoAddress $Config) -or -not $enrollment.role_id -or -not $enrollment.secret_id) {
        throw 'The desktop enrollment does not match the declared installation.'
    }
    $enrollment
}

function Write-DevelopmentEnrollment($Config, $Enrollment) {
    if (-not $IsWindows) { throw 'Desktop enrollment uses Windows user-bound DPAPI.' }
    $path = Get-DevelopmentCredentialPath $Config
    [void](New-Item -ItemType Directory -Path (Split-Path $path) -Force)
    $secure = ConvertTo-SecureString ($Enrollment | ConvertTo-Json -Compress) -AsPlainText -Force
    try { $ciphertext = ConvertFrom-SecureString $secure } finally { $secure.Dispose() }
    # CreateNew preserves an existing enrollment. DPAPI binds ciphertext to this
    # user, and the file ACL excludes other unprivileged local accounts.
    $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $acl = [Security.AccessControl.FileSecurity]::new()
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User,
            [Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','Allow'))
        }
        $bytes = [Text.Encoding]::UTF8.GetBytes($ciphertext)
        $stream.Write($bytes); $stream.Flush($true)
        $stream.Dispose()
        [IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]::new($path), $acl)
    } catch {
        $stream.Dispose()
        Remove-Item -LiteralPath $path -Force
        throw
    } finally { $stream.Dispose() }
}

function Invoke-DevelopmentBao($Config, [string]$Method, [string]$Path, [string]$Token = '', $Body = $null) {
    $parameters = @{ Uri="$(Get-DevelopmentBaoAddress $Config)/v1/$Path"; Method=$Method; TimeoutSec=20; MaximumRedirection=0 }
    if ($Token) { $parameters.Headers = @{ 'X-Vault-Token'=$Token } }
    if ($null -ne $Body) { $parameters.ContentType='application/json'; $parameters.Body=$Body | ConvertTo-Json -Compress }
    try { Invoke-RestMethod @parameters } catch {
        $status = $_.Exception.Response.StatusCode.value__
        throw "OpenBao $Method $Path failed (HTTP $status). Check the declared address, enrollment and policy."
    }
}

function New-DevelopmentBaoSession($Config) {
    $enrollment = Read-DevelopmentEnrollment $Config
    $response = Invoke-DevelopmentBao $Config POST 'auth/approle/login' -Body @{role_id=$enrollment.role_id; secret_id=$enrollment.secret_id}
    if (-not $response.auth.client_token) { throw 'OpenBao did not issue a desktop workload token.' }
    $response.auth.client_token
}

function Get-DevelopmentSecrets($Config) {
    $paths = Get-DevelopmentSecretPaths $Config
    $records = @{}
    if (-not (Test-Path -LiteralPath (Get-DevelopmentCredentialPath $Config))) {
        $savedAddress = $env:BAO_ADDR
        try {
            $env:BAO_ADDR = Get-DevelopmentBaoAddress $Config
            foreach ($key in $paths.Keys) {
                $records[$key] = (Invoke-Program bao @('kv','get','-format=json',$paths[$key]) | ConvertFrom-Json).data.data
            }
        } catch { throw 'Desktop credentials are unavailable. Run bao login locally, then ./laplace.ps1 enroll-development once. Do not put tokens in source or machine.env.' }
        finally { $env:BAO_ADDR = $savedAddress }
        return $records
    }
    $token = New-DevelopmentBaoSession $Config
    try {
        foreach ($key in $paths.Keys) {
            $records[$key] = (Invoke-DevelopmentBao $Config GET ($paths[$key] -replace '^kv/', 'kv/data/') $token).data.data
        }
    } finally { $null = Invoke-DevelopmentBao $Config POST 'auth/token/revoke-self' $token @{} }
    $records
}
