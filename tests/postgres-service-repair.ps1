#Requires -Version 7
# Exercise the installed-service selection and authenticated recovery boundaries.
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot '../setup.ps1'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw ($errors -join '; ') }
foreach ($name in 'Get-PgRepairPlan','Set-PgServiceStartupTimeout','Confirm-PgRecovery','repair-postgres') {
    $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$false)
    if (-not $definition) { throw "Missing installer function: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}
$PgService='laplace-postgres'; $PgAccount='NT AUTHORITY\NetworkService'
$PgDir='E:\fixture\postgres'; $PgBin=Join-Path $PgDir 'bin'; $PgData='E:\fixture\data'
$base='"E:\fixture\postgres\bin\pg_ctl.exe" runservice -N "laplace-postgres" -D "E:\fixture\data" -w'
$script:registration=[pscustomobject]@{ImagePath=$base;ObjectName=$PgAccount}
$script:calls=0
function Get-Service { param($Name) [pscustomobject]@{Status='Stopped'} }
function Get-ItemProperty { param($LiteralPath) $script:registration }
function Exec { param($Exe,[string[]]$Arguments)
    if ($Exe -ne 'sc.exe' -or ($Arguments[0..2] -join '|') -ne 'config|laplace-postgres|binPath=') { throw 'Unexpected service mutation' }
    $script:calls++; $script:registration.ImagePath=$Arguments[3]
}
function Assert($Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Refuses([scriptblock]$Action,[string]$Message) {
    $refused=$false; try { & $Action } catch { $refused=$true }
    Assert $refused $Message
}
$plan=Get-PgRepairPlan
Assert ($plan.change_required -and $plan.startup_timeout_seconds -eq 60) 'Default startup wait not detected'
Set-PgServiceStartupTimeout $plan
Assert ($script:calls -eq 1 -and -not (Get-PgRepairPlan).change_required) 'Startup wait correction did not converge'
Set-PgServiceStartupTimeout (Get-PgRepairPlan)
Assert ($script:calls -eq 1) 'Repeated repair changed an already corrected service'
$script:registration.ImagePath=$base+' -t 2400'
Assert (-not (Get-PgRepairPlan).change_required) 'Longer operator-declared wait was rejected'
$script:registration.ImagePath=$base.Replace('E:\fixture\data','E:\other\data')
Refuses { Get-PgRepairPlan } 'Another cluster was accepted'
$script:registration.ImagePath=$base; $script:registration.ObjectName='LocalSystem'
Refuses { Get-PgRepairPlan } 'Another service account was accepted'
Assert ($script:calls -eq 1) 'Rejected service selection performed a mutation'
$script:row='12345|f|E:\fixture\data|ahart|sspi:fixture-owner'
function TunePsql { param($Sql) $script:row }
Assert ((Confirm-PgRecovery '12345').cluster -eq '12345') 'Original cluster recovery was rejected'
Refuses { Confirm-PgRecovery '99999' } 'Different cluster passed authenticated readback'
$script:row='12345|t|E:\fixture\data|ahart|sspi:fixture-owner'
Refuses { Confirm-PgRecovery '12345' } 'Incomplete recovery was accepted'
$script:row='12345|f|E:\other\data|ahart|sspi:fixture-owner'
Refuses { Confirm-PgRecovery '12345' } 'Different storage passed authenticated readback'
function TunePsql { throw 'Authentication failed' }
Refuses { Confirm-PgRecovery '12345' } 'Authentication refusal was accepted as recovery'
$ReadOnlyPgRepair=$false; $failed=[Collections.Generic.List[string]]::new()
$script:registration.ImagePath=$base+' -t 1200'; $script:registration.ObjectName=$PgAccount
$script:stopped=$false; $script:activated=$false
function Part { param($Name) }
function Say { param($Name,$Message) }
function Get-PgClusterIdentity { '12345' }
function Stop-UnmanagedPostgres { $script:stopped=$true }
function RuntimeClosure { $script:activated=$true }
function deps { param([string[]]$Names,[switch]$SkipRuntimeClosure)
    Assert $SkipRuntimeClosure 'Build phase attempted runtime activation'
    throw 'Injected codec configuration failure'
}
$scratch=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$logDir=Join-Path $scratch ('postgres-repair-test-'+[guid]::NewGuid().ToString('N'))
if (-not $logDir.StartsWith($scratch.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Scratch path escaped temp storage' }
$null=New-Item -ItemType Directory -Path $logDir
try {
    Refuses { repair-postgres } 'Codec build failure was accepted'
    Assert (-not $script:stopped -and -not $script:activated) 'Codec build failure interrupted a recovered database'
    $receipt=Get-Content (Join-Path $logDir '*.json') -Raw | ConvertFrom-Json
    Assert ($receipt.status -eq 'failed' -and $receipt.stage -eq 'repair-codecs' -and -not $receipt.completed) 'Build failure receipt did not preserve the failed stage'
} finally { Remove-Item -LiteralPath $logDir -Recurse -Force }
'PASS installer service selection, timeout convergence and authenticated recovery failure boundaries'
