#Requires -Version 7
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9@._-]+$')][string]$ControlHost,
    [Parameter(Mandatory)][ValidatePattern('^/[A-Za-z0-9/._-]+$')][string]$Gcloud,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]+$')][string]$Project,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]+$')][string]$Zone,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]+$')][string]$CloudHost,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9@._-]+$')][string]$ApplicationHost,
    [Parameter(Mandatory)][string]$PublicBase,
    [Parameter(Mandatory)][string]$PublicMcp,
    [string]$InstallPrefix = '/opt/laplace',
    [ValidatePattern('^[A-Za-z0-9_-]+$')][string]$ServiceUser = 'laplace-runner'
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../secrets/process.ps1"
function CloudState {
    (Invoke-Program ssh @('-o','BatchMode=yes',$ControlHost,"$Gcloud compute instances describe $CloudHost --project=$Project --zone=$Zone --format='value(status)'" )).Trim()
}
$before = CloudState
if ($before -ne 'TERMINATED') { throw "This check requires the cloud host off; observed $before. No power state was changed." }
$program = @'
import json,pathlib,shlex,subprocess,sys,urllib.request,urllib.error
p=json.load(sys.stdin); prefix=pathlib.Path(p['prefix'])
for name in ('base','mcp'):
 if not p[name].startswith('https://'):raise SystemExit('Public verification requires HTTPS')
receipt=prefix/'app/logs/cloud-off-verification.json'
check=subprocess.run([sys.executable,str(prefix/'app/operations/scripts/verify-application-release.py'),
 '--base',p['base'],'--state-file',str(receipt),'--timeout-seconds','10'],text=True,capture_output=True,timeout=45)
if check.returncode:raise SystemExit('Public application verification failed: '+check.stdout+check.stderr)
env={}
for line in (prefix/'app/laplace-api.env').read_text().splitlines():
 if line.strip() and not line.lstrip().startswith('#') and '=' in line:
  key,_,value=line.partition('='); parsed=shlex.split(value); env[key]=parsed[0] if parsed else ''
def host(connection):return next((v.strip() for k,v in (x.split('=',1) for x in connection.split(';') if '=' in x) if k.strip().lower()=='host'),None)
knowledge=host(env.get('LAPLACE_DB','')); application=host(env.get('LAPLACE_APP_DB',''))
if not knowledge or application not in ('localhost','127.0.0.1','::1') or knowledge==application:raise SystemExit('Application and knowledge placement are not distinct')
token=next(shlex.split(x.partition('=')[2])[0] for x in (prefix/'secrets/mcp.env').read_text().splitlines() if x.startswith('LAPLACE_MCP_TOKEN='))
data=json.dumps({'jsonrpc':'2.0','id':1,'method':'initialize','params':{'protocolVersion':'2025-06-18','capabilities':{},'clientInfo':{'name':'cloud-off-acceptance','version':'1'}}}).encode()
codes=[]
for authenticated,expected in [(False,401),(True,200)]:
 headers={'Content-Type':'application/json','Accept':'application/json, text/event-stream'}
 if authenticated:headers['Authorization']='Bearer '+token
 try:
  with urllib.request.urlopen(urllib.request.Request(p['mcp'],data=data,headers=headers),timeout=10) as r:code=r.status;body=r.read(1048576).decode()
 except urllib.error.HTTPError as e:code=e.code;body=e.read(1048576).decode()
 if code!=expected:raise SystemExit('MCP returned '+str(code)+' instead of '+str(expected))
 if authenticated and ('protocolVersion' not in body or 'serverInfo' not in body):raise SystemExit('MCP did not return the initialization contract')
 codes.append(code)
print(json.dumps({'knowledge_host':knowledge,'application_host':application,'release':(prefix/'app/.laplace-source-revision').read_text().strip(),
 'public_api':p['base'],'public_mcp':p['mcp'],'api_verification':json.loads(receipt.read_text()),'mcp_statuses':codes}))
'@
$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($program))
$payload = @{prefix=$InstallPrefix; base=$PublicBase; mcp=$PublicMcp} | ConvertTo-Json -Compress
$result = Invoke-Program ssh @('-o','BatchMode=yes',$ApplicationHost,"sudo -n -u $ServiceUser python3 -c 'import base64;exec(base64.b64decode(`"$encoded`"))'") $payload | ConvertFrom-Json
$after = CloudState
if ($after -ne 'TERMINATED') { throw 'The cloud host changed state during the verification; the result cannot prove cloud-off serving.' }
[ordered]@{verified=$true; cloud_host=$CloudHost; cloud_state_before=$before; cloud_state_after=$after; production=$result} | ConvertTo-Json -Depth 6
