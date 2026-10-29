#Requires -Version 7
[CmdletBinding()]
param(
    [ValidateSet('prepare','activate','verify','resources','resources-check')][string]$Phase = 'prepare',
    [string]$Target = 'production',
    [string]$Installation = "$PSScriptRoot/application-runtime-installation.json"
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/process.ps1"
function Sh([string]$Value) { "'" + $Value.Replace("'", "'\''") + "'" }
function New-ApplicationRuntimeVerification($Configuration,[string]$Repository){
    # Verification executes the canonical owner's readback in memory. It does
    # not install scripts, create remote scratch, or replace serving artifacts.
    $owner=Join-Path $Repository 'deploy/linux/runtime/application-runtime.py'
    if(-not [IO.Path]::IsPathFullyQualified($Repository) -or -not(Test-Path -LiteralPath $owner -PathType Leaf)){throw 'The declared monorepo runtime verifier is missing.'}
    if($Configuration.host -notmatch '^[a-zA-Z0-9._-]+$'){throw 'Invalid runtime verification host.'}
    $loader='import io,json,sys; p=json.load(sys.stdin); sys.stdin=io.StringIO(json.dumps(p["configuration"])); sys.argv=["application-runtime.py","--phase","verify","--stdout-only"]; exec(compile(p["source"],"<laplace-runtime-verification>","exec"),{"__name__":"__main__","__file__":"<laplace-runtime-verification>"})'
    @{arguments=@('sudo','-n','python3','-c',$loader);payload=(@{source=[IO.File]::ReadAllText($owner);configuration=$Configuration}|ConvertTo-Json -Depth 20 -Compress)}
}
if($MyInvocation.InvocationName -eq '.'){return}
$targets = Get-Content -LiteralPath $Installation -Raw | ConvertFrom-Json -AsHashtable
if (-not $targets.ContainsKey($Target)) { throw 'No application runtime installation declared for this target.' }
$config = $targets[$Target]
$root = "kv/hosts/$($config.host)"
if($Phase -eq 'verify'){
    . "$PSScriptRoot/../laplace.env.ps1"
    $repository=if($env:LAPLACE_MONOREPO){$env:LAPLACE_MONOREPO}else{Join-Path $env:LAPLACE_SRC 'Laplace'}
    $request=New-ApplicationRuntimeVerification $config $repository
    $command=($request.arguments|ForEach-Object {Sh $_}) -join ' '
    Invoke-Program ssh @('-o','BatchMode=yes',$config.host,$command) $request.payload -TimeoutSeconds 300
    return
}
if ($Phase -eq 'prepare') {
    if ($config.bao_role -notmatch '^[a-z][a-z0-9_-]*$' -or $config.host -notmatch '^[a-zA-Z0-9._-]+$' -or $config.record -notmatch '^[a-z][a-z0-9_-]*$') {
        throw 'Invalid workload policy declaration.'
    }
    # KV-v2 data endpoints are explicit; no host wildcard, migration credential,
    # metadata listing, credential writes or shared-secret access is granted.
    $policy = "path `"kv/data/hosts/$($config.host)/substrate`" { capabilities = [`"read`"] }`npath `"kv/data/hosts/$($config.host)/$($config.record)`" { capabilities = [`"read`"] }`n"
    $null = Invoke-Program bao @('policy','write',$config.bao_role,'-') $policy
    $null = Invoke-Program bao @('write',"auth/approle/role/$($config.bao_role)","token_policies=$($config.bao_role)",'token_ttl=5m','token_max_ttl=10m','secret_id_ttl=0','secret_id_num_uses=0')
    & ssh -o BatchMode=yes $config.host ('sudo -n test -s ' + (Sh $config.credentials))
    $present = $LASTEXITCODE
    if ($present -notin 0,1) { throw 'Cannot inspect the declared workload enrollment path.' }
    if ($present -eq 1) {
        $roleId = (Invoke-Program bao @('read','-format=json',"auth/approle/role/$($config.bao_role)/role-id") | ConvertFrom-Json).data.role_id
        $secretId = (Invoke-Program bao @('write','-f','-format=json',"auth/approle/role/$($config.bao_role)/secret-id") | ConvertFrom-Json).data.secret_id
        $enrollment = @{role_id=$roleId;secret_id=$secretId} | ConvertTo-Json -Compress
        $writer = 'import os,sys; p=sys.argv[1]; fd=os.open(p,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600); f=os.fdopen(fd,"w"); f.write(sys.stdin.read()); f.close()'
        $null = Invoke-Program ssh @('-o','BatchMode=yes',$config.host,('sudo -n python3 -c ' + (Sh $writer) + ' ' + (Sh $config.credentials))) $enrollment
        $roleId=$null; $secretId=$null; $enrollment=$null
    }
}
$path = "$root/$($config.record)"
if ($Phase -in 'prepare','activate') {
$names = @(Invoke-Program bao @('kv','list','-format=json',$root) | ConvertFrom-Json)
if ($config.record -notin $names) {
    $record = @{ database_host=$config.database_host; database=$config.database; role=$config.role; port=$config.port;
        password=[Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant() }
    $null = Invoke-Program bao @('kv','put','-cas=0',$path,'-') ($record | ConvertTo-Json -Compress)
}
$record = (Invoke-Program bao @('kv','get','-format=json',$path) | ConvertFrom-Json).data.data
foreach ($key in 'database_host','database','role','port') {
    if ([string]$record.$key -ne [string]$config[$key]) { throw 'Existing OpenBao runtime selection differs from the declared installation.' }
}
$config.password = $record.password
$record = $null
}
$remote = $config.work.TrimEnd('/')
$null = Invoke-Program ssh @('-o','BatchMode=yes',$config.host,('sudo -n install -d -o "$(id -un)" -- ' + (Sh $remote)))
foreach ($file in 'application-runtime.py','database-sync.py') {
    & scp "$PSScriptRoot/$file" "$($config.host):$remote/$file"
    if ($LASTEXITCODE) { throw "Cannot transfer runtime installer $file" }
}
if ($Phase -in 'resources','resources-check') {
    & scp "$PSScriptRoot/../tune-pg.sh" "$($config.host):$remote/tune-pg.sh"
    if ($LASTEXITCODE) { throw 'Cannot transfer the declared database tuner.' }
}
$command = (@('sudo','-n','python3',"$remote/application-runtime.py",'--phase',$Phase) | ForEach-Object { Sh $_ }) -join ' '
Invoke-Program ssh @('-o','BatchMode=yes',$config.host,$command) ($config | ConvertTo-Json -Compress) -TimeoutSeconds 300
$config.password = $null
if ($Phase -eq 'prepare') {
    $arguments = @('sudo','-n','python3',"$remote/database-sync.py",'--host',$config.host,'--credentials',$config.credentials,
        '--user',$config.runtime_user,'--prefix',$config.prefix,'--machine-file',$config.machine_file,
        '--lock',$config.host_lock,'--bao-address',$config.bao_address,'--application-record',$config.record)
    Invoke-Program ssh @('-o','BatchMode=yes',$config.host,(($arguments | ForEach-Object { Sh $_ }) -join ' '))
}
