# Publication uses the stable host configuration and an unprivileged restart.
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../installation/modular-web.ps1"
$root=Join-Path ([IO.Path]::GetTempPath()) ('laplace-modular-web-'+[Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root
function Require($Value,[string]$Message){if(-not $Value){throw $Message}}
try {
    $hostDirectory=Join-Path $root 'web'
    $release=Join-Path $root 'releases/release & content'
    $null=New-Item -ItemType Directory -Path $hostDirectory,$release
    [xml]$configuration=Get-ModularWebConfig $hostDirectory $release ('a'*64) (Join-Path $root 'logs/iis')
    $ancm=$configuration.configuration.'system.webServer'.aspNetCore
    Require ($ancm.arguments -eq ('--contentRoot "'+$release+'"')) 'The immutable content directory was not preserved through XML escaping.'
    Require ([IO.Path]::GetFullPath((Join-Path $hostDirectory $ancm.processPath)) -eq (Join-Path $release 'Laplace.Modular.Web.exe')) 'The host selected another executable.'
    Require ($ancm.environmentVariables.environmentVariable.value -eq ('a'*64)) 'The running release identifier was omitted.'
    Write-ModularWebJson (Join-Path $hostDirectory 'state.json') @{release='old'}
    Write-ModularWebJson (Join-Path $hostDirectory 'state.json') @{release='new'}
    Require ((Get-Content (Join-Path $hostDirectory 'state.json') -Raw|ConvertFrom-Json).release -eq 'new') 'Atomic publication did not replace the pointer.'
    Require (@(Get-ChildItem $hostDirectory -Filter '*.tmp').Count -eq 0) 'Atomic publication left temporary files.'
    $reader=[Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
    $null=Grant-ModularWebNativeRead $release $reader
    $null=Grant-ModularWebNativeRead $release $reader
    $grants=@((Get-Acl -LiteralPath $release).GetAccessRules($true,$false,[Security.Principal.SecurityIdentifier])|Where-Object {$_.IdentityReference -eq $reader -and $_.AccessControlType -eq 'Allow'})
    Require ($grants.Count -eq 1) 'Repeated publication duplicated the native reader grant.'
    Require (($grants[0].FileSystemRights -band [Security.AccessControl.FileSystemRights]::ReadAndExecute) -eq [Security.AccessControl.FileSystemRights]::ReadAndExecute) 'The reader cannot traverse and execute the selected native release.'
    Require (($grants[0].FileSystemRights -band [Security.AccessControl.FileSystemRights]::Write) -eq 0) 'The native reader was granted write access.'
    Require ($grants[0].InheritanceFlags -eq [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit') 'The reader grant does not reach native binaries and resources.'
    function Invoke-WebRequest { [pscustomobject]@{Content=[IO.File]::ReadAllText((Join-Path $hostDirectory 'app_offline.htm'))} }
    Restart-ModularWeb $hostDirectory 'https://fixture.invalid/modular/'
    Require (-not(Test-Path -LiteralPath (Join-Path $hostDirectory 'app_offline.htm'))) 'The successful restart left the application offline.'
    function Invoke-WebRequest { throw 'fixture transport failure' }
    $failed=$false
    try {Restart-ModularWeb $hostDirectory 'https://fixture.invalid/modular/'}catch{$failed=$_.Exception.Message -eq 'fixture transport failure'}
    Require $failed 'The restart swallowed its transport failure.'
    Require (-not(Test-Path -LiteralPath (Join-Path $hostDirectory 'app_offline.htm'))) 'The failed restart left the application offline.'
    $clientPath=Join-Path $root 'mcp.json'
    $identity=@{type='http';url='https://fixture.invalid/mcp';headers=@{Authorization='Bearer fixture-identity'}}
    $fixture=@{servers=@{laplace=$identity;'laplace-code'=@{type='stdio';command='python';args=@('-I','C:/Users/fixture/AppData/Local/Laplace/bin/laplace.py','mcp')};other=@{type='stdio';command='fixture-other'}};inputs=@(@{id='preserved';password=$true})}
    Write-ModularWebJson $clientPath $fixture
    $result=Set-ModularMcpClient $clientPath 'https://fixture.invalid' 'https://fixture.invalid/modular/mcp'
    $client=Get-Content -Raw $clientPath|ConvertFrom-Json
    Require ($result.status -eq 'configured' -and $client.servers.'laplace-code'.type -eq 'http') 'The native MCP client remained on stdio.'
    Require ($client.servers.'laplace-code'.url -ceq 'https://fixture.invalid/modular/mcp' -and -not $client.servers.'laplace-code'.command -and -not $client.servers.'laplace-code'.env) 'The HTTP client retained a parallel local launcher.'
    Require ($client.servers.'laplace-code'.headers.Authorization -ceq $client.servers.laplace.headers.Authorization) 'The existing IIS identity was not preserved.'
    Require ($client.servers.other.command -ceq 'fixture-other' -and $client.inputs[0].id -ceq 'preserved') 'Migration changed unrelated MCP configuration.'
    Require ((Set-ModularMcpClient $clientPath 'https://fixture.invalid' 'https://fixture.invalid/modular/mcp').status -eq 'current') 'MCP HTTP migration was not idempotent.'
    $rejected=$false
    try{Set-ModularMcpClient $clientPath 'https://fixture.invalid' 'https://another.invalid/mcp'|Out-Null}catch{$rejected=$true}
    Require $rejected 'MCP credentials could be redirected to another origin.'
    'PASS modular host XML, immutable content path, release identity, atomic pointer, owner native-read grant, unprivileged restart and failure cleanup'
} finally {
    if([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($root)) -ne [IO.Path]::GetTempPath().TrimEnd('\','/')){throw 'Invalid fixture cleanup root.'}
    Remove-Item -LiteralPath $root -Recurse -Force
}
