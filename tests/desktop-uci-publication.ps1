$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot '../../Laplace-UCI/setup-iis.ps1'
$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$null,[ref]$parseErrors)
if($parseErrors){throw ($parseErrors|Out-String)}
foreach($name in 'Write-Atomic','Connector-WebConfig','Restart-UciPool'){
    $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    if(-not $definition){throw "Missing UCI publication helper: $name"}
    Invoke-Expression $definition.Extent.Text
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('laplace-uci-publication-'+[Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root
function Require($Value,[string]$Message){if(-not $Value){throw $Message}}
try{
    $hostDirectory=Join-Path $root 'releases/legacy-host'
    $release=Join-Path $root 'releases/new & immutable'
    $null=New-Item -ItemType Directory -Path $hostDirectory,$release
    $c=[pscustomobject]@{directory=$root;hostname='fixture.invalid'}
    [xml]$configuration=Connector-WebConfig (Join-Path $root 'state') $hostDirectory $release
    $ancm=$configuration.configuration.'system.webServer'.aspNetCore
    Require ([IO.Path]::GetFullPath((Join-Path $hostDirectory $ancm.processPath)) -eq (Join-Path $release 'laplace-uci-connect.exe')) 'The stable UCI host selected another executable.'
    Require ($ancm.arguments -eq ('serve --configuration "'+(Join-Path $root 'connector.json')+'"')) 'The installed connector configuration was not retained.'
    $configurationPath=Join-Path $hostDirectory 'web.config'
    Write-Atomic $configurationPath 'previous'
    Write-Atomic $configurationPath $configuration.OuterXml
    Require (([xml][IO.File]::ReadAllText($configurationPath)).configuration.'system.webServer'.aspNetCore.processPath -eq $ancm.processPath) 'Atomic UCI publication did not replace its launch pointer.'
    function Invoke-WebRequest {[pscustomobject]@{Content=[Text.Encoding]::UTF8.GetBytes([IO.File]::ReadAllText((Join-Path $hostDirectory 'app_offline.htm')))}}
    Restart-UciPool $hostDirectory
    Require (-not(Test-Path -LiteralPath (Join-Path $hostDirectory 'app_offline.htm'))) 'Successful UCI restart left the host offline.'
    function Invoke-WebRequest {throw 'fixture UCI transport failure'}
    $failed=$false
    try{Restart-UciPool $hostDirectory}catch{$failed=$_.Exception.Message -eq 'fixture UCI transport failure'}
    Require $failed 'UCI restart swallowed its transport failure.'
    Require (-not(Test-Path -LiteralPath (Join-Path $hostDirectory 'app_offline.htm'))) 'Failed UCI restart left the host offline.'
    $publication=$ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -eq '$Package'}
    Require ($null -ne $publication) 'UCI package publication branch was not found.'
    $topologyWrites=@($publication.FindAll({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left -is [Management.Automation.Language.MemberExpressionAst] -and $node.Left.Member.Value -eq 'PhysicalPath'},$true))
    Require ($topologyWrites.Count -eq 0) 'Ordinary UCI publication still changes privileged IIS topology.'
    'PASS UCI stable legacy host, immutable executable selection, atomic launch pointer, non-elevated restart, byte response handling, failure cleanup and setup-only IIS topology.'
}finally{Remove-Item -LiteralPath $root -Recurse -Force}