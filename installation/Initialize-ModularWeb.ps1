#requires -Version 7
[CmdletBinding()]
param([string]$Installation=(Join-Path $PSScriptRoot 'hart-desktop-modular-web.json'))
$ErrorActionPreference='Stop'
$c=Get-Content -LiteralPath $Installation -Raw|ConvertFrom-Json
$operator=Get-Content -LiteralPath (Join-Path $PSScriptRoot $c.operator_declaration) -Raw|ConvertFrom-Json
$user=[Security.Principal.WindowsIdentity]::GetCurrent()
if($user.User.Value -ne $operator.windows_sid -or -not ([Security.Principal.WindowsPrincipal]::new($user)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Use the elevated declared desktop operator for database identity provisioning.'}
$n=$c.native
if($n.role -notmatch '^[a-z_][a-z0-9_]{0,62}$' -or $n.database -notmatch '^[a-z_][a-z0-9_-]{0,62}$' -or $c.pool -notmatch '^[a-z][a-z0-9-]*$'){throw 'Invalid declared service identity.'}
$owner="host=HART-DESKTOP hostaddr=127.0.0.1 dbname=$($n.database) user=ahart sslmode=verify-full sslrootcert=$($n.certificate) require_auth=sspi connect_timeout=5"
$data=(& $n.psql $owner -X -A -t -v ON_ERROR_STOP=1 -c 'SHOW data_directory').Trim()
if($LASTEXITCODE -or [IO.Path]::GetFullPath($data) -ine [IO.Path]::GetFullPath($n.postgres_data)){throw 'The declared PostgreSQL cluster is not the connected database.'}
$role=$n.role;$database=$n.database
$sql=@"
DO `$provision`$ BEGIN
 IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='$role') THEN CREATE ROLE $role LOGIN; END IF;
END `$provision`$;
ALTER ROLE $role LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 4;
ALTER ROLE $role IN DATABASE "$database" SET default_transaction_read_only=on;
ALTER ROLE $role IN DATABASE "$database" SET statement_timeout='20s';
GRANT CONNECT ON DATABASE "$database" TO $role;
GRANT USAGE ON SCHEMA public TO $role;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO $role;
ALTER DEFAULT PRIVILEGES FOR ROLE ahart IN SCHEMA public GRANT SELECT ON TABLES TO $role;
"@
$sql | & $n.psql $owner -X -q -v ON_ERROR_STOP=1
if($LASTEXITCODE){throw 'Read-only native service database grants failed.'}
$hba=Join-Path $data 'pg_hba.modular-web.conf';$ident=Join-Path $data 'pg_ident.modular-web.conf'
"hostssl $database $role 127.0.0.1/32 sspi map=laplace_modular_web include_realm=1 compat_realm=1"|Set-Content -LiteralPath $hba -Encoding utf8NoBOM
"laplace_modular_web `"$($c.pool)@IIS APPPOOL`" $role"|Set-Content -LiteralPath $ident -Encoding utf8NoBOM
foreach($entry in @(@('pg_hba.conf','pg_hba.modular-web.conf'),@('pg_ident.conf','pg_ident.modular-web.conf'))){
    $path=Join-Path $data $entry[0];$text=[IO.File]::ReadAllText($path);$line='include_if_exists '+$entry[1]
    if($text -notmatch ('(?m)^'+[regex]::Escape($line)+'\s*$')){[IO.File]::WriteAllText($path,$line+"`n"+$text,[Text.UTF8Encoding]::new($false))}
}
& $n.psql $owner -X -q -v ON_ERROR_STOP=1 -c 'SELECT pg_reload_conf();'
if($LASTEXITCODE){throw 'PostgreSQL authentication reload failed.'}
$installed=Get-Content -LiteralPath $n.client_installation -Raw|ConvertFrom-Json
if($installed.database -cne $n.database){throw 'The selected modular installation names a different database.'}
$root=[IO.Path]::GetFullPath($c.directory);$state=Join-Path $root 'state';$null=New-Item -ItemType Directory -Force -Path $state
$certificate=Join-Path $state 'postgres-root.crt';Copy-Item -LiteralPath $n.certificate -Destination $certificate
$config=[ordered]@{release=$installed.release;database=$n.database;host='HART-DESKTOP';role=$role;certificate=$certificate;threads=2}
$config|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $state 'native.json') -Encoding utf8NoBOM
Write-Host "Configured ${role}: read-only SSPI access to $database for IIS pool $($c.pool)."

# The IIS application stays on this stable directory. Routine publication only
# replaces its ANCM configuration and selects an immutable application release.
. "$PSScriptRoot/modular-web.ps1"
$hostDirectory=Join-Path $root 'web'
$logs=Join-Path $state 'logs/iis'
$null=New-Item -ItemType Directory -Force -Path $hostDirectory,$logs,$c.receipts
Add-Type -Path "$env:windir/System32/inetsrv/Microsoft.Web.Administration.dll"
$manager=[Microsoft.Web.Administration.ServerManager]::new()
try {
    $site=$manager.Sites[$c.site]
    if(-not $site){throw 'The declared parent IIS site is not installed.'}
    $origin=[Uri]$c.origin
    if(-not @($site.Bindings|Where-Object {$_.Protocol -eq 'https' -and $_.Host -ieq $origin.DnsSafeHost -and $_.EndPoint.Port -eq $origin.Port}).Count){throw 'The parent site does not own the declared HTTPS origin.'}
    $parentDirectory=$site.Applications['/'].VirtualDirectories['/'].PhysicalPath
    $application=$site.Applications[$c.application]
    if($application -and ($application.ApplicationPoolName -cne $c.pool -or -not [IO.Path]::GetFullPath($application.VirtualDirectories['/'].PhysicalPath).StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase))){throw 'The declared child application belongs to another installation.'}
    if(@($manager.Sites|ForEach-Object {$siteName=$_.Name;$_.Applications|Where-Object {$_.ApplicationPoolName -eq $c.pool -and ($siteName -ne $c.site -or $_.Path -ne $c.application)}}).Count){throw 'The modular pool is shared with another application.'}
    $pool=$manager.ApplicationPools[$c.pool]
    if(-not $pool){$pool=$manager.ApplicationPools.Add($c.pool)}
    $pool.ManagedRuntimeVersion='';$pool.StartMode='AlwaysRunning';$pool.AutoStart=$true;$pool.ProcessModel.IdentityType='ApplicationPoolIdentity'
    if(-not $application){$application=$site.Applications.Add($c.application,$hostDirectory)}
    $activePath=Join-Path $root 'active.json'
    if(Test-Path -LiteralPath $activePath){
        $active=Get-Content -LiteralPath $activePath -Raw|ConvertFrom-Json
        if($active.release -notmatch '^[a-f0-9]{64}$' -or [IO.Path]::GetFullPath($active.directory) -ine (Join-Path $root ('releases/'+$active.release))){throw 'The active modular release does not belong to this installation.'}
        Write-ModularWebFile (Join-Path $hostDirectory 'web.config') (Get-ModularWebConfig $hostDirectory $active.directory $active.release $logs)
    }
    $application.VirtualDirectories['/'].PhysicalPath=$hostDirectory
    $application.ApplicationPoolName=$c.pool;$application.SetAttributeValue('preloadEnabled',$true)
    $manager.CommitChanges()
    if($pool.State -eq 'Stopped'){$null=$pool.Start()}else{$null=$pool.Recycle()}
} finally {$manager.Dispose()}
$sid=([Security.Principal.NTAccount]::new('IIS APPPOOL',$c.pool)).Translate([Security.Principal.SecurityIdentifier])
foreach($target in @($installed.release,$state)){
    $acl=Get-Acl -LiteralPath $target
    foreach($grant in @(@($sid,'ReadAndExecute'),@([Security.Principal.SecurityIdentifier]::new($operator.windows_sid),'FullControl'),@([Security.Principal.SecurityIdentifier]::new('S-1-5-18'),'FullControl'),@([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'),'FullControl'))){
        $rule=[Security.AccessControl.FileSystemAccessRule]::new($grant[0],[Security.AccessControl.FileSystemRights]$grant[1],([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit),[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)
        $acl.SetAccessRule($rule)
    }
    Set-Acl -LiteralPath $target -AclObject $acl
}
foreach($target in @($root,$hostDirectory,$state)){
    $acl=Get-Acl -LiteralPath $target
    $rule=[Security.AccessControl.FileSystemAccessRule]::new($sid,'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow')
    $acl.SetAccessRule($rule);Set-Acl -LiteralPath $target -AclObject $acl
}
$acl=Get-Acl -LiteralPath (Join-Path $state 'logs')
$acl.SetAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'Modify','ContainerInherit,ObjectInherit','None','Allow'))
Set-Acl -LiteralPath (Join-Path $state 'logs') -AclObject $acl
$acl=Get-Acl -LiteralPath $parentDirectory
$acl.SetAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'ReadAndExecute','ObjectInherit','NoPropagateInherit','Allow'))
Set-Acl -LiteralPath $parentDirectory -AclObject $acl
Write-ModularWebJson (Join-Path $state 'hosting.json') ([ordered]@{schema='laplace.modular-web-host/v1';directory=$hostDirectory;parent_directory=$parentDirectory;site=$c.site;application=$c.application;pool=$c.pool;origin=$c.origin})
Write-Host "Configured IIS host $($c.site)$($c.application) at $hostDirectory. Publish-ModularWeb.ps1 runs as the desktop operator."
