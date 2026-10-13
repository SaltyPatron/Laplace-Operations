#Requires -Version 7
. "$PSScriptRoot/../secrets/process.ps1"

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
