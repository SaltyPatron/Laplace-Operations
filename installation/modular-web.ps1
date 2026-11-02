# Shared deployment configuration; provisioning and publication have separate owners.
function Write-ModularWebJson([string]$Path,$Value) {
    Write-ModularWebFile $Path (ConvertTo-Json -InputObject $Value -Depth 12)
}

function Write-ModularWebFile([string]$Path,[string]$Content) {
    $temporary=$Path+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [IO.File]::WriteAllText($temporary,$Content,[Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary,$Path,$true)
    } finally { if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary} }
}

function Set-ModularMcpClient([string]$Path,[string]$Origin,[string]$Endpoint) {
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return @{status='not_configured'}}
    $configuration=Get-Content -Raw -LiteralPath $Path|ConvertFrom-Json
    $existing=$configuration.servers.'laplace-code'
    if(-not $existing){return @{status='not_configured'}}
    $identity=$configuration.servers.laplace
    if($identity.type -cne 'http' -or ([Uri]$identity.url).GetLeftPart([UriPartial]::Authority) -cne $Origin.TrimEnd('/') -or
        -not $identity.headers.Authorization){throw 'The native MCP client requires the existing same-origin IIS identity.'}
    if(([Uri]$Endpoint).Scheme -cne 'https' -or ([Uri]$Endpoint).GetLeftPart([UriPartial]::Authority) -cne $Origin.TrimEnd('/')){throw 'The native MCP endpoint must use the declared HTTPS origin.'}
    if($existing.type -eq 'http' -and $existing.url -cne $Endpoint){throw 'The native MCP client already selects another HTTP endpoint.'}
    if($existing.type -eq 'stdio' -and (-not @($existing.args|Where-Object {$_ -match '[\\/]Laplace[\\/]bin[\\/]laplace\.py$'}).Count -or 'mcp' -notin $existing.args)){throw 'The stdio client is not the installed Laplace MCP wrapper.'}
    if($existing.type -notin @('stdio','http')){throw 'Unsupported native MCP client transport.'}
    $selected=[pscustomobject]@{type='http';url=$Endpoint;headers=$identity.headers;version='0.2.0'}
    if(($existing|ConvertTo-Json -Depth 20 -Compress) -ceq ($selected|ConvertTo-Json -Depth 20 -Compress)){return @{status='current';transport='http';endpoint=$Endpoint}}
    $configuration.servers.'laplace-code'=$selected
    Write-ModularWebFile $Path ($configuration|ConvertTo-Json -Depth 30)
    return @{status='configured';transport='http';endpoint=$Endpoint}
}

# Each immutable native release is owned by the operator. Publication grants
# the already provisioned application identity read/execute on that release.
function Grant-ModularWebNativeRead([string]$Path,[Security.Principal.SecurityIdentifier]$Principal) {
    $directory=Get-Item -LiteralPath $Path -Force
    if(-not $directory.PSIsContainer -or ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'The native release must be a real directory.'}
    # Change only the DACL. Set-Acl can request audit privileges when persisting
    # a protected package descriptor, even though its owner may grant access.
    $grant='*'+$Principal.Value+':(OI)(CI)(RX)'
    $result=& icacls $directory.FullName /grant:r $grant 2>&1
    if($LASTEXITCODE){throw ('Cannot grant native reader access: '+($result -join ' '))}
    return [ordered]@{directory=$directory.FullName;principal=$Principal.Value;rights='ReadAndExecute'}
}

function Get-ModularWebConfig([string]$HostDirectory,[string]$ReleaseDirectory,[string]$Release,[string]$Logs) {
    if($Release -notmatch '^[a-f0-9]{64}$'){throw 'Invalid modular web release.'}
    $executable=[IO.Path]::GetRelativePath($HostDirectory,(Join-Path $ReleaseDirectory 'Laplace.Modular.Web.exe'))
    $escape={param($value) [Security.SecurityElement]::Escape($value)}
    $processPath=& $escape $executable
    $arguments=& $escape ('--contentRoot "'+$ReleaseDirectory+'"')
    $logPath=& $escape $Logs
    return @"
<?xml version="1.0" encoding="utf-8"?>
<configuration><system.webServer><aspNetCore processPath="$processPath" arguments="$arguments" hostingModel="inprocess" stdoutLogEnabled="true" stdoutLogFile="$logPath"><environmentVariables><environmentVariable name="ReleaseId" value="$Release"/></environmentVariables></aspNetCore></system.webServer></configuration>
"@
}

function Restart-ModularWeb([string]$HostDirectory,[string]$Origin) {
    $offline=Join-Path $HostDirectory 'app_offline.htm'
    $marker='laplace-modular-restart-'+[Guid]::NewGuid().ToString('N')
    $content='<!doctype html><html><body>Application restarting. <!-- '+$marker+' --></body></html>'
    $stream=$null;$created=$false
    try {
        $stream=[IO.File]::Open($offline,'CreateNew','Write','Read');$created=$true
        $bytes=[Text.Encoding]::UTF8.GetBytes($content);$stream.Write($bytes,0,$bytes.Length);$stream.Dispose();$stream=$null
        for($attempt=0;$attempt -lt 20;$attempt++) {
            $response=Invoke-WebRequest ($Origin+'health') -NoProxy -SkipHttpErrorCheck -TimeoutSec 10
            $body=if($response.Content -is [byte[]]){[Text.Encoding]::UTF8.GetString($response.Content)}else{[string]$response.Content}
            if($body.Contains($marker)){return}
            Start-Sleep -Milliseconds 250
        }
        throw 'The declared modular application did not serve its restart marker.'
    } finally {
        if($stream){$stream.Dispose()}
        if($created){
            if([IO.File]::ReadAllText($offline) -cne $content){throw 'The modular offline marker changed; it was preserved.'}
            Remove-Item -LiteralPath $offline
        }
    }
}
