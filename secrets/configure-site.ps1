#Requires -Version 7
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9._-]*$')][string]$HostName,
    [Parameter(Mandatory)][string]$InstallPrefix,
    [string]$IdentityPath = 'kv/shared/laplace-auth',
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9@._-]*$')][string]$SshTarget = $HostName,
    [string]$HostLock = '/run/lock/laplace/host-resource.lock',
    [switch]$UseSudo
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/process.ps1"

# A per-host operator credential is created once in the existing secrets service.
# Secret material travels through process stdin, never command arguments or output.
$secretPath = "kv/hosts/$HostName/laplace-api"
$hosts = Invoke-Program bao @('kv','list','-format=json','kv/hosts') | ConvertFrom-Json
$listing = if ("$HostName/" -in @($hosts)) {
    Invoke-Program bao @('kv','list','-format=json',"kv/hosts/$HostName") | ConvertFrom-Json
} else { @() }
if ('laplace-api' -notin @($listing)) {
    $token = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
    $null = Invoke-Program bao @('kv','put','-cas=0',$secretPath,'operator_token=-') $token
}
$record = (Invoke-Program bao @('kv','get','-format=json',$secretPath) | ConvertFrom-Json).data.data
$identity = (Invoke-Program bao @('kv','get','-format=json',$IdentityPath) | ConvertFrom-Json).data.data
if (-not $record.operator_token) { throw "Missing operator_token in $secretPath" }
$payload = @{
    prefix = $InstallPrefix
    lock = $HostLock
    files = @{
        'operator.env' = @{LAPLACE_OPERATOR_TOKEN = $record.operator_token}
        'identity.env' = @{}
    }
}
foreach ($provider in 'google','microsoft') {
    $id = $identity."${provider}_client_id"; $secret = $identity."${provider}_client_secret"
    if ([bool]$id -ne [bool]$secret) { throw "Incomplete $provider identity in $IdentityPath" }
    if ($id) {
        $payload.files['identity.env']["LAPLACE_AUTH_$($provider.ToUpperInvariant())_CLIENT_ID"] = $id
        $payload.files['identity.env']["LAPLACE_AUTH_$($provider.ToUpperInvariant())_CLIENT_SECRET"] = $secret
    }
}
if ($payload.files['identity.env'].Count -eq 0) { throw "No identity providers in $IdentityPath" }
$remote = @'
import fcntl,json,os,pathlib,shlex,sys,tempfile
p=json.load(sys.stdin)
root=pathlib.Path(p['prefix'])
if not root.is_absolute(): raise SystemExit('Installation prefix must be absolute')
directory=root/'secrets'
if not directory.is_dir(): raise SystemExit('Declared installation has no secrets directory')
changed=[]
lock=open(p['lock'],'a')
try: fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
except BlockingIOError: raise SystemExit('Another deployment or ingest owns the host lock')
updates=[]
for name,values in p['files'].items():
    if name not in ('operator.env','identity.env'): raise SystemExit('Unknown site credential file')
    target=directory/name
    if target.is_symlink(): raise SystemExit('Credential file must not be a symbolic link')
    current={}
    if target.exists():
        for line in target.read_text().splitlines():
            if not line.strip() or line.lstrip().startswith('#'): continue
            key,sep,value=line.partition('=')
            if not sep: raise SystemExit('Malformed existing credential file')
            parsed=shlex.split(value)
            current[key]=parsed[0] if parsed else ''
    for key,value in values.items():
        if not isinstance(value,str) or not value or any(c in value for c in '\r\n\x00'):
            raise SystemExit('Missing or unsupported credential value')
        if key in current and current[key]!=value:
            raise SystemExit('Installed credential differs from OpenBao; explicit rotation required')
    merged={**current,**values}
    if current==merged and target.exists(): continue
    data=''.join(k+'='+json.dumps(v,ensure_ascii=False)+'\n' for k,v in merged.items())
    updates.append((name,target,data))
# Validate every selected record before changing any installed credential.
for name,target,data in updates:
    fd,temporary=tempfile.mkstemp(prefix='.'+name+'.',dir=directory)
    try:
        with os.fdopen(fd,'w') as stream:
            stream.write(data); stream.flush(); os.fsync(stream.fileno())
        os.chmod(temporary,0o640)
        os.replace(temporary,target)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)
    changed.append(name)
print(json.dumps({'changed':changed,'prefix':str(root),'restart_required':bool(changed)}))
'@
# Quoting only a constant Python program; credentials are the SSH process's stdin.
$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remote))
$launcher = if ($UseSudo) { 'sudo -n python3' } else { 'python3' }
$command = "$launcher -c 'import base64;exec(base64.b64decode(`"$encoded`"))'"
$result = Invoke-Program ssh @('-o','BatchMode=yes','-o','ConnectTimeout=10',$SshTarget,$command) ($payload | ConvertTo-Json -Depth 6 -Compress)
$payload = $null; $record = $null; $identity = $null; $token = $null
$result
