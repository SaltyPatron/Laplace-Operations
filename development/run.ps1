#Requires -Version 7
[CmdletBinding()]
param(
    [string]$SourcePath,
    [ValidatePattern('^[a-zA-Z0-9-]+$')][string]$RunId,
    [string]$Installation = $(if ($env:LAPLACE_DEVELOPMENT_INSTALLATION) { $env:LAPLACE_DEVELOPMENT_INSTALLATION } else { "$PSScriptRoot/installation.json" }),
    [switch]$Verify
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../laplace.env.ps1"
. "$PSScriptRoot/../secrets/process.ps1"
. "$PSScriptRoot/credentials.ps1"
if (-not $SourcePath) { $SourcePath = Join-Path $env:LAPLACE_SRC 'Laplace' }
$SourcePath = (Resolve-Path -LiteralPath $SourcePath).Path
$env:LAPLACE_ROOT = $SourcePath
. "$PSScriptRoot/../toolchain/windows/devshell.ps1"
. (Join-Path $SourcePath 'scripts/win/laplace-paths.ps1')
Import-LaplaceEnv
$config = Get-Content -LiteralPath $Installation -Raw | ConvertFrom-Json
$apiPort = if ($env:LAPLACE_API_PORT) { [int]$env:LAPLACE_API_PORT } else { [int]$config.api_port }
if ($apiPort -lt 1 -or $apiPort -gt 65535) { throw 'Invalid development API port.' }
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$apiPort)
try { $listener.Start() } catch { throw "Port $apiPort is already in use. Stop its current process or select another LAPLACE_API_PORT." } finally { $listener.Stop() }
$project = Join-Path $SourcePath 'app/Laplace.Endpoints.OpenAICompat/Laplace.Endpoints.OpenAICompat.csproj'
$api = (Invoke-Program dotnet @('msbuild',$project,'-getProperty:TargetPath','-p:Configuration=Release','-p:Platform=AnyCPU')).Trim()
if (-not (Test-Path -LiteralPath $api)) { throw 'Build this checkout first: ./laplace.ps1 build' }
$web = Join-Path $SourcePath 'web/dist'
if (-not (Test-Path -LiteralPath "$web/index.html")) { throw 'Build this checkout first: the web distribution is missing.' }
if (-not (Test-Path -LiteralPath $env:LAPLACE_PERFCACHE_BIN)) { throw 'The configured native Tier-0 artifact is missing; run ./laplace.ps1 build.' }
$app = Split-Path $api
[void](New-Item -ItemType Directory -Path "$app/wwwroot" -Force)
Get-ChildItem -LiteralPath $web | Copy-Item -Destination "$app/wwwroot" -Recurse -Force
$stamp = if ($RunId) { $RunId } else { [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8) }
$work = Join-Path $env:LAPLACE_WORK "operations/desktop-run-$stamp"
[void](New-Item -ItemType Directory -Path $work -Force)
$root = "kv/hosts/$($config.client)"
$records = Get-DevelopmentSecrets $config
function Connection($Record, [string]$Database, [string]$Role) {
    if ($Record.database_host -ne $config.database_host -or $Record.database -ne $Database -or $Record.role -ne $Role -or $Record.port -ne $config.port) {
        throw 'OpenBao selection differs from the declared development installation.'
    }
    if ($Record.password -notmatch '^[0-9a-f]{64}$' -or $Record.database_host -notmatch '^[a-zA-Z0-9._-]+$' -or $Role -notmatch '^[a-z][a-z0-9_-]*$' -or $Database -notmatch '^[a-z][a-z0-9_-]*$') {
        throw 'Invalid development database credential contract.'
    }
    $pool = [int]$config.pool_max
    if ($pool -lt 1) { throw 'pool_max must be positive.' }
    "Host=$($Record.database_host);Port=$($Record.port);Database=$Database;Username=$Role;Password=$($Record.password);SSL Mode=Require;Maximum Pool Size=$pool"
}
$env:LAPLACE_DB = Connection $records.knowledge $config.knowledge_database $config.knowledge_role
$env:LAPLACE_APP_DB = Connection $records.appdb $config.application_database $config.application_role
$env:LAPLACE_OPERATOR_TOKEN = $records.'laplace-api'.operator_token
if (-not $env:LAPLACE_OPERATOR_TOKEN) { throw 'Development operator identity is missing; run development/configure.ps1.' }
$identity = $records.identity
foreach ($provider in 'google','microsoft') {
    $id = $identity."${provider}_client_id"; $secret = $identity."${provider}_client_secret"
    if ([bool]$id -ne [bool]$secret) { throw "Incomplete $provider identity in $($config.identity_reference)" }
    if ($id) {
        [Environment]::SetEnvironmentVariable("LAPLACE_AUTH_$($provider.ToUpperInvariant())_CLIENT_ID", $id, 'Process')
        [Environment]::SetEnvironmentVariable("LAPLACE_AUTH_$($provider.ToUpperInvariant())_CLIENT_SECRET", $secret, 'Process')
    }
}
$identity = $null; $secret = $null; $records = $null
$env:LAPLACE_AUTH_MODE = 'identity'
$env:LAPLACE_BILLING_STORE = 'postgres'
$env:LAPLACE_API_PORT = [string]$apiPort
$env:LAPLACE_PUBLIC_BASE_URL = "http://localhost:$apiPort"
$env:LAPLACE_OPS_LOG_DIR = Join-Path $work 'logs'
$env:LAPLACE_DATA_PROTECTION_KEYS = Join-Path $env:LAPLACE_WORK 'development/keys'
Remove-Item Env:LAPLACE_AUTH_DEV_PRINCIPAL,Env:LAPLACE_API_KEY -ErrorAction SilentlyContinue
$receipt = [ordered]@{ source=$SourcePath; revision=(& git -C $SourcePath rev-parse HEAD); dirty_source=[bool]@(& git -C $SourcePath status --porcelain --untracked-files=no);
    build_root=$env:LAPLACE_BUILD_ROOT; base_url=$env:LAPLACE_PUBLIC_BASE_URL; knowledge_database=$config.knowledge_database;
    application_database=$config.application_database; database_host=$config.database_host; knowledge_role=$config.knowledge_role;
    application_role=$config.application_role; pool_max_per_serving_datasource=$config.pool_max;
    credential_reference=$root; started_utc=[DateTime]::UtcNow.ToString('o'); status='failed' }
$process = $null
try {
    $process = Start-Process -FilePath (Get-Command dotnet).Source -ArgumentList @(('"' + $api + '"')) -WorkingDirectory $app -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput "$work/api.stdout.log" -RedirectStandardError "$work/api.stderr.log"
    $receipt.process_id = $process.Id
    $receipt.process_started_utc = $process.StartTime.ToUniversalTime().ToString('o')
    $receipt.api_path = $api
    $receipt.control_version = 1
    Write-Host "Logs and receipt: $work"
    & py -3 (Join-Path $SourcePath 'scripts/verify-application-release.py') --base $env:LAPLACE_PUBLIC_BASE_URL --state-file "$work/verification.json" --timeout-seconds 60
    if ($LASTEXITCODE) { throw "Desktop runtime verification failed; inspect $work" }
    $auth = Invoke-RestMethod "$($env:LAPLACE_PUBLIC_BASE_URL)/v1/auth/config"
    $receipt.sign_in_providers = @($auth.providers | ForEach-Object { $_.id })
    if ($receipt.sign_in_providers.Count -eq 0) { throw 'The desktop has no configured sign-in provider.' }
    if ($Verify) {
        $receipt.status = 'verified'
    } else {
        Write-Host "Laplace is ready: $($env:LAPLACE_PUBLIC_BASE_URL)"
        Write-Host 'Press Ctrl+C to stop this development process.'
        $receipt.status = 'running'
        $receipt | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$work/receipt.json"
        while (-not $process.WaitForExit(500)) {
            if (Test-Path -LiteralPath (Join-Path $work 'stop.request')) {
                $receipt.status = 'stopped'
                $process.Kill($true); $process.WaitForExit()
                break
            }
        }
        if ($process.ExitCode -ne 0 -and $receipt.status -ne 'stopped') { throw "API exited with $($process.ExitCode); inspect $work" }
        $receipt.status = 'stopped'
    }
} catch {
    $receipt.status = 'failed'
    throw
} finally {
    if ($null -ne $process -and -not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
    if ($receipt.status -eq 'running') { $receipt.status = 'stopped' }
    $receipt.finished_utc = [DateTime]::UtcNow.ToString('o')
    $receipt | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$work/receipt.json"
}
