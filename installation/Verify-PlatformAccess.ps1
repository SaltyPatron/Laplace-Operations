#Requires -Version 7
[CmdletBinding()]
param(
    [string]$Configuration="$PSScriptRoot/hart-desktop-operator.json",
    [string]$Development="$PSScriptRoot/../development/installation.json"
)
$ErrorActionPreference='Stop'
$c=Get-Content -LiteralPath $Configuration -Raw | ConvertFrom-Json
$d=Get-Content -LiteralPath $Development -Raw | ConvertFrom-Json
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if($identity.User.Value -ne $c.windows_sid -or $identity.Name -ne $c.windows_identity -or
    $d.database_host -ine $env:COMPUTERNAME -or $d.authentication -ne 'sspi'){
    throw 'Select the declared Windows operator and local development application database.'
}
$base=([Uri]$c.platform_access.browser_origin)
$network=Get-Content -LiteralPath "$PSScriptRoot/../network/environments.json" -Raw | ConvertFrom-Json
$target=@($network.environments | Where-Object host -IEQ $env:COMPUTERNAME)
if($target.Count -ne 1 -or $target[0].browser_origin -ne $base.GetLeftPart([UriPartial]::Authority) -or
    $base.Scheme -ne 'https' -or $base.UserInfo -or $base.Query -or $base.Fragment -or $base.AbsolutePath -ne '/'){
    throw 'The browser origin does not match this installed environment.'
}
$base=$base.GetLeftPart([UriPartial]::Authority)
$expected=@($c.platform_access.administrators)
if(-not $expected.Count){throw 'No platform administrator identities are declared.'}
$saved=@{}
foreach($item in @(Get-ChildItem Env: | Where-Object Name -Like 'PG*')){
    $saved[$item.Name]=$item.Value
    Remove-Item -LiteralPath ('Env:'+$item.Name)
}
$token=$null
try {
    $env:PGSSLMODE='verify-full'; $env:PGSSLROOTCERT=$d.root_certificate
    $env:PGREQUIREAUTH='sspi'; $env:PGCONNECT_TIMEOUT='10'
    # Read provider bindings and grants, never session tickets or client credentials.
    $sql=@'
SELECT coalesce(json_agg(row_to_json(p)), '[]'::json) FROM (
    SELECT u.user_id, i.provider, i.issuer, i.subject, r.role,
        i.last_login_at,
        EXISTS(SELECT 1 FROM app.platform_role_events e WHERE e.user_id=u.user_id AND e.role=r.role) AS audited
    FROM app.users u JOIN app.external_identities i USING(user_id)
    LEFT JOIN app.platform_roles r USING(user_id)
) p;
'@
    $raw=& $d.psql -X -w -h $d.database_host -p $d.port -U $d.admin_role -d $d.application_database -Atq -v ON_ERROR_STOP=1 -c $sql 2>&1
    if($LASTEXITCODE){throw 'Cannot inspect the selected application identity store.'}
    $bindings=($raw -join "`n") | ConvertFrom-Json
    foreach($person in $expected){
        $match=@($bindings | Where-Object { $_.user_id -eq $person.user_id -and $_.provider -ceq $person.provider -and
            $_.issuer -ceq $person.issuer -and $_.subject -ceq $person.subject })
        if($match.Count -ne 1 -or $match[0].role -cne 'administrator' -or -not $match[0].last_login_at -or -not $match[0].audited){
            throw "Missing authenticated provider binding or audited administrator grant: $($person.provider) / $($person.user_id)"
        }
    }
    . "$PSScriptRoot/../development/credentials.ps1"
    $token=New-DevelopmentBaoSession $d
    $path=(Get-DevelopmentSecretPaths $d)['laplace-api'] -replace '^kv/','kv/data/'
    $record=(Invoke-DevelopmentBao $d GET $path $token).data.data
    if(-not $record.operator_token){throw 'The enrolled installation credential is missing.'}
    $headers=@{'X-Laplace-Operator-Token'=$record.operator_token}
    $people=(Invoke-RestMethod "$base/v1/admin/access/people" -Headers $headers -MaximumRedirection 0 -TimeoutSec 20).people
    $auth=Invoke-RestMethod "$base/v1/auth/config" -MaximumRedirection 0 -TimeoutSec 20
    foreach($person in $expected){
        $match=@($people | Where-Object { $_.userId -eq $person.user_id -and $_.role -ceq 'administrator' -and $_.providers -ccontains $person.provider })
        if($match.Count -ne 1 -or @($auth.providers | Where-Object id -CEQ $person.provider).Count -ne 1){
            throw "The serving application does not expose the declared provider and administrator grant: $($person.provider)"
        }
    }
    $anonymous=Invoke-WebRequest "$base/v1/admin/access/people" -SkipHttpErrorCheck -MaximumRedirection 0 -TimeoutSec 20
    if($anonymous.StatusCode -notin 401,403){throw 'The platform access directory is not denied to an anonymous request.'}
    [ordered]@{
        host=$env:COMPUTERNAME; checked_utc=[DateTime]::UtcNow.ToString('o'); browser_origin=$base
        application_database=$d.application_database; administrators=$expected
        provider_bindings='passed'; persisted_audited_roles='passed'; serving_application_readback='passed'
        anonymous_directory_status=[int]$anonymous.StatusCode
        browser_session_verification='not performed; this check does not impersonate a browser session'
        passed=$true
    } | ConvertTo-Json -Depth 6
} finally {
    $headers=$null; $record=$null
    try { if($token){$null=Invoke-DevelopmentBao $d POST 'auth/token/revoke-self' $token @{}} }
    finally {
        $token=$null
        foreach($item in @(Get-ChildItem Env: | Where-Object Name -Like 'PG*')){Remove-Item -LiteralPath ('Env:'+$item.Name)}
        foreach($name in $saved.Keys){[Environment]::SetEnvironmentVariable($name,$saved[$name])}
    }
}
