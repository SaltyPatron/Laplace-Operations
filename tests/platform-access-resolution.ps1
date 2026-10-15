#Requires -Version 7
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../installation/platform-access-verification.ps1"
function Refused([scriptblock]$Action){
    try{& $Action}catch{
        if($_.Exception.Message -match 'private-subject|00000000-0000-0000-0000-00000000000[12]'){throw 'Private identity escaped in a verification error.'}
        return
    }
    throw 'Unsafe administrator verification was accepted.'
}
$expected=@([pscustomobject]@{provider='google';issuer='https://accounts.google.com';subject='private-subject';user_id='00000000-0000-0000-0000-000000000001'})
$binding=[pscustomobject]@{provider='google';issuer='https://accounts.google.com';subject='private-subject';user_id='00000000-0000-0000-0000-000000000002';role='administrator';audited=$true;last_login_at='2026-01-01T00:00:00Z'}
$people=@([pscustomobject]@{userId=$binding.user_id;role='administrator';providers=@('google');installationOwner=$false})
$providers=@([pscustomobject]@{id='google'})
$resolved=@(Resolve-PlatformAdministratorBindings $expected @($binding) $null)
if($resolved.Count -ne 1 -or $resolved[0].user_id -ne $binding.user_id -or $resolved[0].installation_owner){throw 'Fresh database UUID was not resolved from the exact provider tuple.'}
Test-PlatformAdministratorReadback $resolved $people $providers
Refused {Resolve-PlatformAdministratorBindings $expected @($binding,$binding) $null}
Refused {Resolve-PlatformAdministratorBindings @($expected[0],$expected[0]) @($binding) $null}
$binding.issuer='https://other.invalid'
Refused {Resolve-PlatformAdministratorBindings $expected @($binding) $null}
$binding.issuer=$expected[0].issuer
$binding.subject='other-subject'
Refused {Resolve-PlatformAdministratorBindings $expected @($binding) $null}
$binding.subject=$expected[0].subject
$binding.audited=$false
Refused {Resolve-PlatformAdministratorBindings $expected @($binding) $null}
$binding.audited=$true
$binding.role='operator'
Refused {Resolve-PlatformAdministratorBindings $expected @($binding) $null}
$binding.role='administrator'
$binding.last_login_at=$null
Refused {Resolve-PlatformAdministratorBindings $expected @($binding) $null}
$policy=[pscustomobject]@{version=1;owners=$expected}
$resolved=@(Resolve-PlatformAdministratorBindings $expected @($binding) $policy)
if(-not $resolved[0].installation_owner -or $resolved[0].login_observed){throw 'Preprovisioned owner was confused with an observed login.'}
Refused {Test-PlatformAdministratorReadback $resolved $people $providers}
$people[0].installationOwner=$true
Test-PlatformAdministratorReadback $resolved $people $providers
$people[0].userId=$expected[0].user_id
Refused {Test-PlatformAdministratorReadback $resolved $people $providers}
$people[0].userId=$binding.user_id
Refused {Test-PlatformAdministratorReadback $resolved $people @()}
$people[0].providers=@('microsoft')
Refused {Test-PlatformAdministratorReadback $resolved $people $providers}
$people[0].providers=@('google')
Refused {Test-PlatformAdministratorReadback $resolved @($people[0],$people[0]) $providers}
Write-Host 'Exact provider resolution, recreated UUIDs, audited roles, owner readback, ordinary-login boundary and private errors passed.'
