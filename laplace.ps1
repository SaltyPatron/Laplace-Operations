#Requires -Version 7
<#
.SYNOPSIS
Operate the installed Laplace application through its delivery workflows.
.EXAMPLE
./laplace.ps1 verify -Target staging -Wait
.EXAMPLE
./laplace.ps1 deploy -Wait
.EXAMPLE
./laplace.ps1 db -Database substrate -DatabaseOperation recreate -Yes
.EXAMPLE
./laplace.ps1 ingest wiktionary tatoeba staging -Wait
.EXAMPLE
./laplace.ps1 data status staging
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Operation = 'help',
    [ValidateSet('desktop','staging','production','cloud')][string]$Target,
    [ValidateSet('substrate','application','both')][string]$Database = 'both',
    [ValidateSet('status','migrate','repair','remigrate','recreate','reindex')][string]$DatabaseOperation = 'status',
    [string]$Revision = 'main',
    [string]$Repository = 'SaltyPatron/Laplace',
    [string]$SourcePath,
    [string]$Installation,
    [switch]$Yes,
    [switch]$Wait,
    [switch]$Plan,
    [string]$Components='all',
    [string]$Package,
    [switch]$Force,
    [switch]$AsIs,
    [switch]$Json,
    [string]$Check,
    [switch]$List,
    [switch]$Installed,
    [ValidateSet('status','verify')][string]$ClientOperation = 'status',
    [ValidateSet('status','clean')][string]$StorageOperation = 'status',
    [Alias('h')][switch]$Help,
    [Parameter(ValueFromRemainingArguments)][string[]]$RemainingArgs = @()
)
$ErrorActionPreference = 'Stop'
if ($Operation -in @('clean','cleanup')) { $Operation='storage';$StorageOperation='clean' }
if ($Help -or $Operation -in @('help','-h','--help','/?') -or ($RemainingArgs | Where-Object { $_ -in @('help','-h','--help','/?') })) {
    $Operation = 'help'
} else {
    $Names = @(); $DataOperation = 'status'
    $takesNames = $Operation -in @('ingest','data','seed')                   # source or data-set names, given after the operation
    foreach ($token in $RemainingArgs) {
        if ($Operation -eq 'clients' -and $token -in @('status','verify')) { $ClientOperation=$token; continue }
        if ($Operation -eq 'storage' -and $token -in @('status','clean')) { $StorageOperation=$token; continue }
        if ($Operation -eq 'data' -and $token -in @('status','fetch','record')) { $DataOperation = $token; continue }
        if ($takesNames -and $token -notmatch '^-' -and $token -notin @('desktop','staging','production','cloud','yes','wait')) { $Names += $token; continue }
        switch ($token.ToLowerInvariant()) {
            { $_ -in @('--yes','-y','yes') } { $Yes = $true }
            { $_ -in @('--wait','-w','wait') } { $Wait = $true }
            { $_ -in @('desktop','staging','production','cloud') } {
                $Target = $_
                $PSBoundParameters['Target'] = $_
            }
            { $_ -in @('substrate','application','both','app') } {
                $Database = if ($_ -eq 'app') { 'application' } else { $_ }
            }
            { $_ -in @('status','migrate','repair','remigrate','recreate','reindex','up','reset','nuke') } {
                $DatabaseOperation = switch ($_) {
                    'up'    { 'migrate' }
                    'reset' { 'remigrate' }
                    'nuke'  { 'recreate' }
                    default { $_ }
                }
            }
            default {
                throw "Unrecognized argument '$token'. Run 'laplace-ops help' to see valid commands and options."
            }
        }
    }
}
$validOperations = @('help','status','runs','run','start','stop','logs','configure-development','enroll-development','verify','deploy','components','clients','unify','storage','prepare','build','test','recovery','db','restart-iis','repair-postgres','ingest','seed','sources','data')
if ($Operation -notin $validOperations) {
    throw "Unknown operation '$Operation'. Valid operations: $($validOperations -join ', ')"
}
if ($Operation -eq 'help') {
    @'
Laplace Operator & Developer CLI (laplace-ops) — canonical database: 'laplace'

EVERYDAY COMMANDS
  laplace-ops unify                   Verify CLI, IIS, UCI, PostgreSQL, and live HTTPS all target 'laplace'
  laplace-ops sources [-Json]         List installed ingest sources, aliases, and file locations
  laplace-ops ingest [SOURCE...]      Ingest named sources (or all in recipes/order) into 'laplace'
  laplace-ops seed -Yes [SOURCE...]   Drop/recreate 'laplace', bind caches, and ingest [SOURCE...] (or all)
  laplace-ops db                      Report status of local databases ('laplace' + 'laplace-desktop-app')
  laplace-ops db migrate              Apply declared schemas/extensions + cache bindings to local databases
  laplace-ops db substrate recreate -Yes   Drop, recreate, and bind caches for canonical 'laplace'
  laplace-ops db application recreate -Yes Drop and recreate 'laplace-desktop-app' only
  laplace-ops deploy desktop          Package CLI/MCP, publish IIS, migrate, and verify installed release
  laplace-ops verify desktop [-Installed]  Verify dev server or installed IIS package

REMOTE STAGING / PRODUCTION (GitHub Actions: Laplace-Operations operate.yml / laplace.yml / ingest.yml)
  laplace-ops runs                    List recent GitHub Actions runs across all Laplace repositories
  laplace-ops status <staging|production> [-Wait]
  laplace-ops verify <staging|production> [-Wait]
  laplace-ops deploy <staging|production> [-Wait]
  laplace-ops ingest staging [SOURCE...] [-Wait]   Dispatch ingest.yml on hart-server
  laplace-ops seed staging -Yes [-Wait]            Dispatch laplace.yml (drop + deploy + full reseed) on hart-server
  laplace-ops db <staging|cloud> <substrate|application> <status|migrate|repair|recreate|reindex> [-Wait]
  laplace-ops data [staging] [status|fetch|record] [SET...]   Audit/fetch/record corpus data sets

ADVANCED / LOCAL DEVELOPMENT (http://localhost:5187 & https://dev.hartonomous.com)
  laplace-ops prepare | build | test [-List | -Check <id,...>]
  laplace-ops run | start | stop | status | logs
  laplace-ops deploy desktop [-Plan] [-Components web|modular-web|api,cli] [-Force] [-Package <dir>]
  laplace-ops restart-iis | repair-postgres [-Plan]
  laplace-ops configure-development | enroll-development
  laplace-ops components desktop | staging [-Force]
  laplace-ops clients [verify] [-Json] | storage [clean] [-Json] | clean [-Json]
'@ | Write-Host
    exit 0
}
$desktopOperations = @('prepare','build','test','run','start','stop','logs','configure-development','enroll-development','db','restart-iis','repair-postgres','clients','unify','storage','ingest','seed','sources','data')
if (-not $PSBoundParameters.ContainsKey('Target')) {
    $Target = if ($Operation -in $desktopOperations) { 'desktop' } else { 'staging' }
}
if (($Check -or $List) -and ($Operation -ne 'test' -or $Target -ne 'desktop')) { throw '-Check and -List select registered desktop tests; no operation was run.' }
if ($PSBoundParameters.ContainsKey('Check') -and -not @($Check.Split(',')|Where-Object {$_.Trim()}).Count) { throw '-Check requires at least one registered check ID; no build or test was run.' }
if (($Check -or $List) -and ($SourcePath -or $Installation)) { throw 'Registered checks declare their targets and use installed client selections; SourcePath and Installation do not override them.' }
if ($Check -and $List) { throw 'Select -List or -Check, not both.' }
if($PSBoundParameters.ContainsKey('Components') -and -not($Target -eq 'desktop' -and $Operation -in @('deploy','build'))){
    throw '-Components selects desktop build/deployment components; no operation was run.'
}
if($Force -and -not(($Target -eq 'desktop' -and $Operation -in @('deploy','build')) -or ($Target -eq 'staging' -and $Operation -eq 'components'))){
    throw '-Force rebuilds desktop components or explicitly replaces staging native releases; no operation was run.'
}
if($Package -and -not($Target -eq 'desktop' -and $Operation -eq 'deploy')){throw '-Package selects a prepared desktop deployment; no operation was run.'}
if($Installed -and -not($Target -eq 'desktop' -and $Operation -eq 'verify')){throw '-Installed selects desktop runtime verification; no operation was run.'}
if ($Plan -and -not ($Operation -in 'deploy','repair-postgres' -and $Target -eq 'desktop')) {
    throw '-Plan is supported by deploy and repair-postgres on desktop; no operation was run.'
}
if ($Operation -in @('prepare','build','test','run','start','stop','logs','configure-development','enroll-development','restart-iis','repair-postgres') -and $Target -ne 'desktop') {
    throw "$Operation runs on desktop; target '$Target' is not supported. Use deploy to install a deployment target."
}
if ($Operation -eq 'storage') {
    if ($Target -ne 'desktop') {
        if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'Hosted cleanup requires the GitHub CLI.' }
        $hostedOperation=if($StorageOperation -eq 'status'){'storage'}else{'clean'}
        $output=& gh workflow run product-operator.yml --repo $Repository --ref $Revision -f "target=$Target" -f "operation=$hostedOperation" 2>&1
        if($LASTEXITCODE){throw ($output -join "`n")}
        $dispatch=$output -join "`n"
        Write-Output $dispatch
        if($Wait){
            if($dispatch -notmatch '/actions/runs/(\d+)'){throw 'GitHub accepted cleanup without returning a run ID. Use laplace-ops runs.'}
            & gh run watch $Matches[1] --repo $Repository --exit-status --interval 10
            exit $LASTEXITCODE
        }
        exit 0
    }
    . "$PSScriptRoot/laplace.env.ps1"
    . "$PSScriptRoot/installation/desktop-clients.ps1"
    . "$PSScriptRoot/installation/storage.ps1"
    $modular=Get-DesktopClientDeclaration $Installation
    $iis=Read-StorageJson $env:LAPLACE_IIS_INSTALLATION
    $arguments=@{WorkRoot=$env:LAPLACE_WORK;BuildRoot=$env:LAPLACE_BUILD;Modular=$modular;Iis=$iis}
    $state=if ($StorageOperation -eq 'clean') { Invoke-DesktopStorageCleanup @arguments } else { Get-DesktopStoragePlan @arguments }
    if ($Json) { $state | ConvertTo-Json -Depth 10 }
    else {
        if ($StorageOperation -eq 'clean') {
            $delta=($state.drives | ForEach-Object {$_.free_bytes_after-$_.free_bytes_before} | Measure-Object -Sum).Sum
            Write-Host "Cleanup: $($state.removed.Count) unused outputs removed; $([math]::Round($delta/1GB,2)) GiB free-space increase across declared drives."
            $stageRelations=(@($state.database_cleanup | ForEach-Object loads | ForEach-Object relations) | Measure-Object -Sum).Sum
            Write-Host "Native staging: $([long]$stageRelations) disconnected-load relations retired."
        }
        else { $state.entries | Select-Object kind,retire,path,@{n='reason';e={$_.reasons -join ','}} | Format-Table -AutoSize }
        if ($state.receipt) { Write-Host "Storage receipt: $($state.receipt)" }
    }
    exit 0
}
if ($Operation -eq 'clients') {
    if ($Target -ne 'desktop') { throw 'clients inventories the local Windows installation; remote MCP services are verified by their delivery workflows.' }
    . "$PSScriptRoot/installation/desktop-clients.ps1"
    $state=Get-DesktopClientState -Declaration (Get-DesktopClientDeclaration $Installation)
    if ($Json) { $state | ConvertTo-Json -Depth 10 } else { Write-DesktopClientState $state }
    if ($ClientOperation -eq 'verify') {
        if ($state.status -eq 'unverifiable') { exit 1 }
        if ($state.status -eq 'reconnect_required') { exit 2 }
    }
    exit 0
}
if ($Operation -eq 'unify') {
    if ($Target -ne 'desktop') { throw 'unify checks the local Windows installation.' }
    . "$PSScriptRoot/laplace.env.ps1"
    $failures = [Collections.Generic.List[string]]::new()
    $rows = [Collections.Generic.List[object]]::new()

    $binDir = Join-Path $env:LOCALAPPDATA 'Laplace\bin'
    $staleShim = Join-Path $binDir 'laplace-mono.cmd'
    if (Test-Path -LiteralPath $staleShim) {
        $failures.Add("Stale legacy CLI shim exists: $staleShim")
        $rows.Add([pscustomobject]@{ Component='stale-shim'; Target=$staleShim; Database='laplace-mono'; Status='FAIL (stale shim)' })
    }

    $laplaceCmd = Join-Path $binDir 'laplace.cmd'
    if (-not (Test-Path -LiteralPath $laplaceCmd -PathType Leaf)) {
        $failures.Add("Missing installed CLI: $laplaceCmd")
        $rows.Add([pscustomobject]@{ Component='laplace CLI'; Target=$laplaceCmd; Database=''; Status='FAIL (missing)' })
    } else {
        $whereJson = (& $laplaceCmd --where 2>&1) -join "`n"
        if ($LASTEXITCODE -ne 0) {
            $failures.Add("laplace --where failed: $whereJson")
            $rows.Add([pscustomobject]@{ Component='laplace CLI'; Target=$laplaceCmd; Database=''; Status='FAIL (--where error)' })
        } else {
            $w = $whereJson | ConvertFrom-Json
            $ok = ($w.database -ceq 'laplace')
            if (-not $ok) { $failures.Add("laplace CLI points to '$($w.database)' instead of 'laplace'") }
            $rows.Add([pscustomobject]@{ Component='laplace CLI'; Target="$($w.database_host)/$($w.database_role)"; Database=$w.database; Status=$(if($ok){'OK'}else{'FAIL'}) })
        }
    }

    $iisPath = if ($env:LAPLACE_IIS_INSTALLATION) { $env:LAPLACE_IIS_INSTALLATION } else { Join-Path $env:LAPLACE_DATA_ROOT 'services/laplace-mono-api/installation.json' }
    if (-not (Test-Path -LiteralPath $iisPath -PathType Leaf)) {
        $failures.Add("Missing IIS installation manifest: $iisPath")
        $rows.Add([pscustomobject]@{ Component='IIS API'; Target=$iisPath; Database=''; Status='FAIL (missing)' })
    } else {
        $iis = Get-Content -LiteralPath $iisPath -Raw | ConvertFrom-Json
        $subDb = $iis.database.substrate_database
        $appDb = $iis.database.application_database
        $ok = ($subDb -ceq 'laplace')
        if (-not $ok) { $failures.Add("IIS manifest substrate_database is '$subDb' instead of 'laplace'") }
        $rows.Add([pscustomobject]@{ Component='IIS API'; Target="$($iis.database.host) (app=$appDb)"; Database=$subDb; Status=$(if($ok){'OK'}else{'FAIL'}) })
    }

    $uciPath = Join-Path $env:LAPLACE_DATA_ROOT 'services/laplace-mono-uci/agent/installation.json'
    if (-not (Test-Path -LiteralPath $uciPath -PathType Leaf)) {
        $failures.Add("Missing UCI installation manifest: $uciPath")
        $rows.Add([pscustomobject]@{ Component='UCI connector'; Target=$uciPath; Database=''; Status='FAIL (missing)' })
    } else {
        $uci = Get-Content -LiteralPath $uciPath -Raw | ConvertFrom-Json
        $connStr = [string]$uci.connector.profiles.'mono-development'.variables.LAPLACE_DB
        $uciDb = if ($connStr -match '(?:database|dbname)=([^;\s]+)') { $Matches[1] } else { '' }
        $ok = ($uciDb -ceq 'laplace')
        if (-not $ok) { $failures.Add("UCI LAPLACE_DB targets '$uciDb' instead of 'laplace'") }
        $rows.Add([pscustomobject]@{ Component='UCI connector'; Target='mono-development'; Database=$uciDb; Status=$(if($ok){'OK'}else{'FAIL'}) })
    }

    $psql = Join-Path $env:LAPLACE_PG_DIR 'bin\psql.exe'
    if (-not (Test-Path -LiteralPath $psql -PathType Leaf)) {
        $failures.Add("Missing psql: $psql")
        $rows.Add([pscustomobject]@{ Component='PostgreSQL'; Target=$psql; Database=''; Status='FAIL (missing psql)' })
    } else {
        $pgHost = if ($env:LAPLACE_PGHOST) { $env:LAPLACE_PGHOST } else { '127.0.0.1' }
        $pgPort = if ($env:LAPLACE_PGPORT) { $env:LAPLACE_PGPORT } else { '5432' }
        $pgUser = $env:USERNAME
        $dbsRaw = & $psql -X -w -h $pgHost -p $pgPort -U $pgUser -d postgres -Atq -c "SELECT datname FROM pg_database WHERE NOT datistemplate ORDER BY datname;" 2>&1
        if ($LASTEXITCODE -ne 0) {
            $failures.Add("PostgreSQL query failed: $($dbsRaw -join ' ')")
            $rows.Add([pscustomobject]@{ Component='PostgreSQL'; Target="${pgHost}:${pgPort}"; Database=''; Status='FAIL (query)' })
        } else {
            $dbs = @($dbsRaw | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
            $hasLaplace = $dbs -contains 'laplace'
            $hasMono = $dbs -contains 'laplace-mono'
            if (-not $hasLaplace) { $failures.Add("PostgreSQL database 'laplace' is missing") }
            if ($hasMono) { $failures.Add("Legacy database 'laplace-mono' still exists in PostgreSQL") }
            $ok = $hasLaplace -and (-not $hasMono)
            $rows.Add([pscustomobject]@{ Component='PostgreSQL'; Target="${pgHost}:${pgPort} ($($dbs -join ', '))"; Database=$(if($hasLaplace){'laplace'}else{'MISSING'}); Status=$(if($ok){'OK'}else{'FAIL'}) })
        }
    }

    $origin = if ($env:LAPLACE_PUBLIC_BASE_URL) { $env:LAPLACE_PUBLIC_BASE_URL.TrimEnd('/') } else { 'https://dev.hartonomous.com' }
    try {
        $health = Invoke-RestMethod "$origin/health" -TimeoutSec 10
        $ok = ($health.status -eq 'ok')
        if (-not $ok) { $failures.Add("Live IIS /health status was '$($health.status)'") }
        $rows.Add([pscustomobject]@{ Component='IIS HTTPS /health'; Target=$origin; Database=$(if($health.stream){$health.stream}else{'laplace'}); Status=$(if($ok){'OK'}else{'FAIL'}) })
    } catch {
        $failures.Add("Live IIS /health check failed ($origin/health): $($_.Exception.Message)")
        $rows.Add([pscustomobject]@{ Component='IIS HTTPS /health'; Target=$origin; Database='unreachable'; Status='FAIL' })
    }

    $rows | Format-Table -AutoSize
    if ($failures.Count -gt 0) {
        foreach ($f in $failures) { Write-Error $f }
        exit 1
    }
    Write-Host "UNIFIED: all desktop components target canonical 'laplace' with zero 'laplace-mono' leftovers."
    exit 0
}
if ($Operation -eq 'repair-postgres') {
    $repairArgs = @('-NoProfile','-File',"$PSScriptRoot/setup.ps1",'repair-postgres')
    if ($Plan) { $repairArgs += '-Check' }
    & pwsh @repairArgs
    exit $LASTEXITCODE
}
if ($Check -or $List) {
    . "$PSScriptRoot/laplace.env.ps1"
    $arguments=@('-NoProfile','-File',"$PSScriptRoot/acceptance/verify.ps1")
    if ($List) { $arguments+='-List' }
    else {
        $run=Join-Path $env:LAPLACE_WORK ('operations/test-'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ'))
        $arguments+=@('-Check',$Check,'-Output',(Join-Path $run 'receipt.json'))
    }
    & pwsh @arguments
    $result=$LASTEXITCODE
    if(-not $List){
        . "$PSScriptRoot/installation/storage.ps1"
        try{Invoke-OperationHistoryCleanup}catch{Write-Warning "History cleanup failed: $_";if(-not $result){$result=1}}
    }
    exit $result
}
if ($Operation -eq 'db') {
    if ($Target -eq 'desktop') {
        if ($DatabaseOperation -eq 'reindex') { throw 'reindex is only supported for staging/cloud via db-ops.yml.' }
        . "$PSScriptRoot/laplace.env.ps1"
        $source = if ($SourcePath) { [IO.Path]::GetFullPath($SourcePath) } else { Join-Path $env:LAPLACE_SRC 'Laplace' }
        $iisConfig = if ($env:LAPLACE_IIS_INSTALLATION) { $env:LAPLACE_IIS_INSTALLATION } else { Join-Path $env:LAPLACE_DATA_ROOT 'services/laplace-mono-api/installation.json' }
        $scopes = if ($Database -eq 'both') { @('application','substrate') } else { @($Database) }
        if (Test-Path -LiteralPath $iisConfig) {
            $invokeDb = Join-Path $source 'deploy/windows/Invoke-IisDatabase.ps1'
            $result=0
            try {
                foreach ($scope in $scopes) {
                    $dbArgs = @('-NoProfile','-File',$invokeDb,'-Installation',$iisConfig,'-Database',$scope,'-Operation',$DatabaseOperation)
                    if ($Yes) { $dbArgs += '-Yes' }
                    & pwsh @dbArgs
                    $result=$LASTEXITCODE
                    if ($result) { break }
                }
                if ($result -eq 0 -and ($scopes -contains 'substrate') -and $DatabaseOperation -in @('migrate','repair','remigrate','recreate')) {
                    $laplaceCmd = Join-Path $env:LOCALAPPDATA 'Laplace\bin\laplace.cmd'
                    if (Test-Path -LiteralPath $laplaceCmd -PathType Leaf) {
                        & $laplaceCmd deploy --configure-server-cache
                        $result = $LASTEXITCODE
                    }
                }
            } finally {
                . "$PSScriptRoot/installation/storage.ps1"
                try{Invoke-OperationHistoryCleanup}catch{Write-Warning "History cleanup failed: $_";if(-not $result){$result=1}}
            }
            exit $result
        }
        . (Join-Path $source 'scripts/win/laplace-paths.ps1')
        Import-LaplaceEnv
        $migrationsProject = Join-Path $source 'app/Laplace.Migrations/Laplace.Migrations.csproj'
        $migrationsDll = (& dotnet msbuild $migrationsProject -nologo -p:Configuration=Release -p:Platform=AnyCPU -getProperty:TargetPath).Trim()
        if (-not (Test-Path -LiteralPath $migrationsDll)) {
            throw "No IIS installation found at $iisConfig and Laplace.Migrations is not built yet. Run 'laplace-ops build' first."
        }
        if (-not $env:LAPLACE_APP_DB) {
            $appDbName = if ($env:LAPLACE_APP_DBNAME) { $env:LAPLACE_APP_DBNAME } else { 'laplace-desktop-app' }
            $env:LAPLACE_APP_DB = "Host=$env:LAPLACE_PGHOST;Port=$env:LAPLACE_PGPORT;Username=$env:LAPLACE_PGUSER;Database=$appDbName;Command Timeout=0"
        }
        foreach ($scope in $scopes) {
            $commands = switch ("$scope`:$DatabaseOperation") {
                'application:status'    { @(@('app-status'), @('app-check')) }
                'application:migrate'   { @(@('app-up'), @('app-check')) }
                'application:repair'    { @(@('app-up'), @('app-check')) }
                'application:remigrate' { if (-not $Yes) { throw 'Pass -Yes to remigrate.' }; @(@('app-reset','--yes'), @('app-up'), @('app-check')) }
                'application:recreate'  { if (-not $Yes) { throw 'Pass -Yes to recreate.' }; @(@('app-nuke','--yes'), @('app-check')) }
                'substrate:status'      { @(@('substrate-status')) }
                'substrate:migrate'     { @(@('substrate-up')) }
                'substrate:repair'      { @(@('substrate-up')) }
                'substrate:remigrate'   { if (-not $Yes) { throw 'Pass -Yes to remigrate.' }; @(@('reset','--yes'), @('substrate-up')) }
                'substrate:recreate'    { if (-not $Yes) { throw 'Pass -Yes to recreate.' }; @(@('nuke','--yes')) }
            }
            foreach ($cmd in $commands) {
                & dotnet $migrationsDll @cmd
                if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
            }
        }
        exit 0
    }
    if ($Target -notin @('staging','production','cloud')) { throw "db supports desktop, staging, or cloud." }
    if ($Target -eq 'production') { throw 'Use -Target staging or cloud for remote database maintenance.' }
    if ($Database -eq 'both') { throw 'Remote database maintenance requires -Database substrate or -Database application.' }
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'GitHub CLI (gh) is required; sign in with gh auth login.' }
    $dbInputs = @('-f',"target=$Target",'-f',"operation=$DatabaseOperation",'-f',"database=$Database")
    Write-Host "Dispatching db-ops.yml ($Database / $DatabaseOperation) on $Target from $Revision."
    $output = & gh workflow run 'db-ops.yml' --repo $Repository --ref $Revision @dbInputs 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($output -join "`n") }
    $text = $output -join "`n"
    Write-Output $text
    if ($Wait -and $text -match '/actions/runs/(\d+)') {
        & gh run watch $Matches[1] --repo $Repository --exit-status --interval 10
        exit $LASTEXITCODE
    }
    exit 0
}
if ($Operation -in @('ingest','seed','sources','data')) {
    if ($Target -notin @('desktop','staging')) { throw "$Operation supports desktop or staging." }
    if ($Operation -eq 'seed' -and -not $Yes) { throw 'seed drops the database first: pass -Yes.' }
    if ($Target -eq 'desktop') {
        . "$PSScriptRoot/laplace.env.ps1"
        switch ($Operation) {
            'ingest'  { & pwsh -NoProfile -File "$PSScriptRoot/ingest.ps1" @Names; exit $LASTEXITCODE }
            'seed'    { & pwsh -NoProfile -File "$PSScriptRoot/deploy.ps1" drop -Installed; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
                        & pwsh -NoProfile -File "$PSScriptRoot/ingest.ps1" @Names; exit $LASTEXITCODE }
            'sources' { $laplace = Join-Path $env:LOCALAPPDATA 'Laplace/bin/laplace.cmd'
                        if (-not (Test-Path -LiteralPath $laplace -PathType Leaf)) { throw 'The modular client is not installed. Run setup.ps1 client for this host.' }
                        $raw = & $laplace ingest --catalog
                        if ($LASTEXITCODE) { exit $LASTEXITCODE }
                        if ($Json) { $raw; exit 0 }
                        $catalog = ($raw -join "`n") | ConvertFrom-Json
                        foreach ($source in $catalog.sources) {
                            $command = if ($source.aliases.Count) { $source.aliases[0] } else { $source.name }
                            "${command}: $($source.name)"
                            if ($source.aliases.Count) { "  aliases: $($source.aliases -join ', ')" }
                            "  witness: $($source.witness)"
                            "  content: $(($source.files + $source.roots) -join '; ')"
                            foreach ($recipe in $source.recipes) { "  $($recipe.name) [$($recipe.grammar)]: $($recipe.match -join ' ')" }
                            if ($source.reads.Count) { "  formats: $($source.reads -join ', ')" }
                            if ($source.after.Count) { "  after: $($source.after -join ', ')" }
                            if ($source.held) { "  held: $($source.held)" }
                        }
                        'File decomposers:'
                        foreach ($format in $catalog.formats) { "  $($format.name) [$($format.grammar)]: $($format.match -join ' ')" }
                        exit 0 }
            'data'    { $bash = Join-Path $env:ProgramFiles 'Git\bin\bash.exe'
                        if (-not (Test-Path $bash)) { throw "data.sh needs bash: no Git Bash at $bash" }
                        & $bash -c 'python3 -c 1' 2>$null
                        if ($LASTEXITCODE -ne 0) { throw 'data.sh reads laplace.env, which needs python3 in bash; none runs here. Run it where the data is kept: laplace-ops data staging' }
                        & $bash "$PSScriptRoot/data.sh" $DataOperation @Names; exit $LASTEXITCODE }
        }
    }
    if ($Operation -eq 'sources') { throw 'sources reads this machine; on hart-server run laplace sources there.' }
    if ($Operation -eq 'data') {
        if (-not $env:LAPLACE_PEER) { . "$PSScriptRoot/laplace.env.ps1" }
        if (-not $env:LAPLACE_PEER) { throw 'data staging reaches the deployment target over SSH: LAPLACE_PEER (machine.env) names it.' }
        # the target's own checkout, at the LAPLACE_SRC laplace.env gives hart-server
        $remote = (@('/repos/src/Laplace-Operations/data.sh', $DataOperation) + $Names | ForEach-Object { "'" + ($_ -replace "'", "'\''") + "'" }) -join ' '
        & ssh -o BatchMode=yes $env:LAPLACE_PEER $remote
        exit $LASTEXITCODE
    }
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'GitHub CLI (gh) is required; sign in with gh auth login.' }
    # A reseed is the deployment's own path (laplace.yml reseed=true): drop, deploy, modular activation and cache
    # bindings, stamp, then every source. ingest.yml only ingests into the deployed database.
    $workflow = if ($Operation -eq 'seed') { 'laplace.yml' } else { 'ingest.yml' }
    $ingestInputs = if ($Operation -eq 'seed') { @('-f','reseed=true','-f','drop=false') } else { @('-f',"sources=$($Names -join ' ')",'-f','reseed=false') }
    Write-Host ($(if ($Operation -eq 'seed') { 'Reseed hart-server: drop, deploy, activate, ingest every source of LAPLACE_SOURCES.' } elseif ($Names) { "Ingest on hart-server: $($Names -join ' ')." } else { 'Ingest on hart-server: every source of LAPLACE_SOURCES.' }))
    $output = & gh workflow run $workflow --repo 'SaltyPatron/Laplace-Operations' --ref main @ingestInputs 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($output -join "`n") }
    $text = $output -join "`n"; Write-Output $text
    if ($Wait -and $text -match '/actions/runs/(\d+)') { & gh run watch $Matches[1] --repo 'SaltyPatron/Laplace-Operations' --exit-status --interval 10; exit $LASTEXITCODE }
    exit 0
}
if ($Operation -eq 'restart-iis') {
    . "$PSScriptRoot/laplace.env.ps1"
    $source = if ($SourcePath) { [IO.Path]::GetFullPath($SourcePath) } else { Join-Path $env:LAPLACE_SRC 'Laplace' }
    & pwsh -NoProfile -File (Join-Path $source 'deploy/windows/Restart-IisApplication.ps1')
    exit $LASTEXITCODE
}
if ($Operation -eq 'deploy' -and $Target -eq 'desktop') {
    & pwsh -NoProfile -File "$PSScriptRoot/installation/Deploy-Desktop.ps1" -SourcePath $SourcePath -ModularInstallation $Installation -Plan:$Plan -Components $Components -Force:$Force -Package $Package -AsIs:$AsIs
    exit $LASTEXITCODE
}
if ($Operation -eq 'components' -and $Target -eq 'desktop') {
    if (-not $Installation) {
        $hostManifest = Join-Path $PSScriptRoot ('installation/' + $env:COMPUTERNAME.ToLowerInvariant() + '-modular-client.json')
        $Installation = if (Test-Path -LiteralPath $hostManifest) { $hostManifest } else { "$PSScriptRoot/installation/hart-desktop-modular-client.json" }
    }
    Write-Host "Packaging modular desktop stack (Laplace-Native, Laplace-Engine) and updating laplace CLI..."
    & pwsh -NoProfile -File "$PSScriptRoot/installation/install-windows-client.ps1" -Installation $Installation
    exit $LASTEXITCODE
}
if ($Operation -eq 'deploy' -and $Target -notin @('staging','production')) {
    throw 'deploy supports desktop, staging, or production. Use components -Target cloud for on-demand component qualification.'
}
if ($SourcePath -and $Target -ne 'desktop') {
    throw 'SourcePath selects local desktop sources; remote operations use Revision.'
}
if ($Operation -in 'start','stop','logs' -or ($Operation -in 'status','verify' -and $Target -eq 'desktop')) {
    if ($PSBoundParameters.ContainsKey('Target') -and $Target -ne 'desktop') { throw "$Operation is a desktop lifecycle operation; use the deployment operator for another target." }
    if($Installed){
        if($Operation -ne 'verify'){throw '-Installed selects desktop verification.'}
        $localArgs=@('-NoProfile','-File',"$PSScriptRoot/installation/Verify-DesktopRuntime.ps1")
    }else{
        $localArgs=@('-NoProfile','-File',"$PSScriptRoot/development/control.ps1",'-Operation',$Operation)
    }
    if ($SourcePath) { $localArgs+=@('-SourcePath',$SourcePath) }
    & pwsh @localArgs
    $code=$LASTEXITCODE
    if ($code -ne 0) { exit $code }
    exit 0
}
if ($Operation -eq 'enroll-development') {
    & pwsh -NoProfile -File "$PSScriptRoot/development/enroll.ps1"
    exit $LASTEXITCODE
}
if ($Operation -eq 'configure-development') {
    & pwsh -NoProfile -File "$PSScriptRoot/development/configure.ps1"
    exit $LASTEXITCODE
}
if ($Operation -eq 'run') {
    if ($Operation -eq 'run' -and $PSBoundParameters.ContainsKey('Target') -and $Target -ne 'desktop') {
        throw 'run starts the desktop development process; use deploy for a deployment target.'
    }
    $localArgs = @('-NoProfile','-File',"$PSScriptRoot/development/run.ps1")
    if ($SourcePath) { $localArgs += @('-SourcePath',$SourcePath) }
    & pwsh @localArgs
    exit $LASTEXITCODE
}
if ($Operation -in 'prepare','build','test') {
    $localArgs = @('-NoProfile','-File',"$PSScriptRoot/dev.ps1",'-Operation',$Operation)
    if ($SourcePath) { $localArgs += @('-SourcePath',$SourcePath) }
    if ($Operation -eq 'build') { $localArgs+=@('-Components',$Components); if($Force){$localArgs+='-Force'} }
    & pwsh @localArgs
    exit $LASTEXITCODE
}
if ($Target -eq 'desktop') { throw 'Desktop supports prepare, build, test, start, stop, status, logs, run and verify.' }
if ($Operation -eq 'recovery') {
    & pwsh -NoProfile -File "$PSScriptRoot/backup/recovery.ps1" -Target $Target
    exit $LASTEXITCODE
}
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'GitHub CLI (gh) is required; sign in with gh auth login.' }
if ($Operation -eq 'runs') {
    if ($PSBoundParameters.ContainsKey('Repository')) {
        & gh run list --repo $Repository --limit 12
        exit $LASTEXITCODE
    }
    foreach ($repo in @('SaltyPatron/Laplace','SaltyPatron/Laplace-Operations','SaltyPatron/Laplace-Native','SaltyPatron/Laplace-postgres','SaltyPatron/Laplace-Engine','SaltyPatron/Laplace-MCP')) {
        Write-Host "=== $repo ===" -ForegroundColor Cyan
        & gh run list --repo $repo --limit 4
    }
    exit 0
}
$workflow = 'product-operator.yml'
$inputs = @('-f',"operation=$Operation",'-f',"target=$Target")
if ($Operation -eq 'components') {
    if ($Target -eq 'production') { throw 'Use deploy for public production delivery; components supports staging and on-demand cloud-host verification.' }
    if (-not $PSBoundParameters.ContainsKey('Repository')) { $Repository = 'SaltyPatron/Laplace-Operations' }
    $workflow = 'laplace.yml'
    $inputs = @('-f','drop=false','-f','reseed=false')
    if ($Force) { $inputs += @('-f','rebuild_runtime=true') }
    Write-Host "Verify component deployment from $Revision on $Target."
} elseif ($Operation -eq 'deploy') {
    if ($Target -eq 'production') {
        Write-Host "Deploy ${Revision}: staging verification, package transfer, production verification."
    } else {
        Write-Host "Deploy ${Revision} to staging on hart-server."
    }
} else {
    Write-Host "$Operation on $Target using checks from $Revision."
}
$output = & gh workflow run $workflow --repo $Repository --ref $Revision @inputs 2>&1
if ($LASTEXITCODE -ne 0) { throw ($output -join "`n") }
$text = $output -join "`n"
Write-Output $text
if ($Wait) {
    if ($text -notmatch '/actions/runs/(\d+)') {
        throw 'GitHub accepted the operation but did not return its run ID. Use ./laplace.ps1 runs to follow it.'
    }
    $runId = $Matches[1]
    & gh run watch $runId --repo $Repository --exit-status --interval 10
    $operationExit = $LASTEXITCODE
    if ($Operation -in 'status','verify') {
        . "$PSScriptRoot/laplace.env.ps1"
        $evidence = Join-Path $env:LAPLACE_WORK "operations/$runId"
        [void](New-Item -ItemType Directory -Path $evidence -Force)
        & gh run download $runId --repo $Repository --name "application-verification-$Target-$runId" --dir $evidence
        if ($LASTEXITCODE -ne 0) { throw "Cannot retrieve the operation evidence for $runId" }
        Write-Host "Saved installed status and verification: $evidence"
        $receipt = Join-Path $evidence 'application-verification.json'
        if (Test-Path -LiteralPath $receipt) { Get-Content -LiteralPath $receipt }
    }
    exit $operationExit
}
