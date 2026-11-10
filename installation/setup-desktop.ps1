$OpsRoot = if ($OpsRoot) { $OpsRoot } else { Split-Path -Parent $PSScriptRoot }
function Get-PgRepairPlan {
    $service = Get-Service -Name $PgService -ErrorAction Stop
    $registration = Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$PgService"
    $command = '"{0}" runservice -N "{1}" -D "{2}" -w' -f (Join-Path $PgBin 'pg_ctl.exe'), $PgService, $PgData
    $match = [regex]::Match($registration.ImagePath, '^'+[regex]::Escape($command)+'(?: -t (?<seconds>\d+))?$', 'IgnoreCase')
    if (-not $match.Success -or $registration.ObjectName -ine $PgAccount) {
        throw 'The PostgreSQL service does not select the declared executable, data directory and service account; no service changed.'
    }
    $seconds = if ($match.Groups['seconds'].Success) { [int]$match.Groups['seconds'].Value } else { 60 }
    [pscustomobject]@{ service=$PgService; account=$registration.ObjectName; status=[string]$service.Status;
        command=$registration.ImagePath; desired_command=($command+' -t '+[Math]::Max(1200,$seconds));
        startup_timeout_seconds=$seconds; change_required=($seconds -lt 1200); data=$PgData; prefix=$PgDir }
}
function Set-PgServiceStartupTimeout($Plan) {
    if (-not $Plan.change_required) { return }
    # pg_ctl's default 60-second wait can exit while crash recovery continues.
    # SCM then reports Stopped although the surviving postmaster accepts connections.
    Exec sc.exe @('config', $PgService, 'binPath=', $Plan.desired_command)
    if ((Get-PgRepairPlan).change_required) { throw 'PostgreSQL service startup timeout did not converge.' }
}
function Confirm-PgRecovery([string]$ExpectedCluster) {
    $row = ((TunePsql "SELECT system_identifier, pg_is_in_recovery(), current_setting('data_directory'), current_user, coalesce(system_user,'') FROM pg_control_system()") -join '').Trim()
    $values = $row -split '\|'
    if ($values.Count -ne 5 -or $values[0] -ne $ExpectedCluster -or $values[1] -ne 'f' -or
        [IO.Path]::GetFullPath($values[2]).TrimEnd('\','/') -ine [IO.Path]::GetFullPath($PgData).TrimEnd('\','/')) {
        throw 'Authenticated readback did not verify the original cluster, data directory and completed recovery.'
    }
    [pscustomobject]@{cluster=$values[0];in_recovery=$false;data=$values[2];role=$values[3];authenticated_identity=$values[4]}
}
function Stop-UnmanagedPostgres([string]$ExpectedCluster) {
    if ((Get-Service -Name $PgService).Status -ne 'Stopped') { return }
    $pidFile = Join-Path $PgData 'postmaster.pid'
    if (-not (Test-Path -LiteralPath $pidFile)) { return }
    $lines = @(Get-Content -LiteralPath $pidFile)
    $server = Get-Process -Id ([int]$lines[0]) -ErrorAction SilentlyContinue
    if (-not $server) { return } # PostgreSQL itself checks stale PID files at startup.
    if ($lines.Count -lt 2 -or $server.ProcessName -ne 'postgres' -or
        [IO.Path]::GetFullPath($lines[1]).TrimEnd('\','/') -ine [IO.Path]::GetFullPath($PgData).TrimEnd('\','/')) {
        throw 'The stopped service has an unverified live PID file; no process stopped.'
    }
    if (TuneIngesting) { throw 'An ingest owns the database; no PostgreSQL process stopped.' }
    if (PgReady) { $null = Confirm-PgRecovery $ExpectedCluster }
    else {
        $process = Get-CimInstance Win32_Process -Filter "ProcessId=$($server.Id)"
        if (-not $process.ExecutablePath -or [IO.Path]::GetFullPath($process.ExecutablePath) -ine (Join-Path $PgBin 'postgres.exe')) {
            throw 'The recovering postmaster executable cannot be verified; no process stopped.'
        }
    }
    Say 'PostgreSQL repair' 'cleanly stopping the verified postmaster left by the failed service wrapper'
    Exec (Join-Path $PgBin 'pg_ctl.exe') @('-D',$PgData,'-m','fast','-w','-t','1200','stop')
    if (Test-Path -LiteralPath $pidFile) { throw 'The unmanaged postmaster did not stop cleanly; no replacement server started.' }
}
function Get-PgClusterIdentity {
    $control = @(& (Join-Path $PgBin 'pg_controldata.exe') $PgData 2>&1)
    if ($LASTEXITCODE) { throw "Cannot read the original cluster control file: $($control -join ' ')" }
    $cluster = (($control | Select-String '^Database system identifier:\s+(\d+)$').Matches.Groups[1].Value)
    if (-not $cluster) { throw 'Cannot identify the original PostgreSQL cluster.' }
    $cluster
}
function repair-postgres {
    Part 'PostgreSQL runtime repair'
    $plan = Get-PgRepairPlan
    $cluster = Get-PgClusterIdentity
    if ($ReadOnlyPgRepair) {
        [ordered]@{mode='read-only';cluster=$cluster;service=$plan;codecs=@('lz4','zstd');
            actions=@('converge service timeout','build and verify declared codec DLLs',
                'stop a verified unmanaged postmaster if present','refresh runtime with binary backups',
                'start service','verify authenticated original-cluster recovery')} | ConvertTo-Json -Depth 6
        return
    }
    $receiptPath = Join-Path $logDir ('postgres-repair-'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ')+'.json')
    $receipt = [ordered]@{host=$env:COMPUTERNAME;cluster=$cluster;service=$PgService;data=$PgData;
        started_utc=[DateTime]::UtcNow.ToString('o');status='started';stage='service-configuration';completed=$false}
    function Save-PgRepair { $receipt | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $receiptPath }
    Save-PgRepair
    try {
        # Configure first: an access refusal must not stop a database that recovered.
        Set-PgServiceStartupTimeout $plan
        $receipt.stage='repair-codecs'; Save-PgRepair
        deps -Names @('lz4','zstd') -SkipRuntimeClosure
        if ($failed.Count) { throw ($failed -join '; ') }
        $receipt.stage='activate-runtime'; Save-PgRepair
        Stop-UnmanagedPostgres $cluster
        RuntimeClosure
        $receipt.stage='start-and-verify'; Save-PgRepair
        if ((Get-Service -Name $PgService).Status -eq 'Stopped') { Start-Service -Name $PgService }
        $deadline = [DateTime]::UtcNow.AddSeconds(1200)
        while ((Get-Service -Name $PgService).Status -ne 'Stopped' -and -not (PgReady) -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Seconds 2
        }
        if ((Get-Service -Name $PgService).Status -ne 'Running' -or -not (PgReady)) {
            throw "PostgreSQL service did not become running and ready; see $PgLogs. Corrected codec binaries remain installed."
        }
        $receipt.readback = Confirm-PgRecovery $cluster
        $receipt.codecs = @(foreach ($codec in 'lz4','zstd') {
            $library = Join-Path $PgBin "${codec}.dll"
            [ordered]@{name=$codec;path=$library;sha256=(Get-FileHash -LiteralPath $library).Hash}
        })
        $receipt.status='passed'; $receipt.completed=$true; $receipt.stage='verified'
    } catch { $receipt.status='failed'; $receipt.error=$_.Exception.Message; throw }
    finally { Save-PgRepair; Say 'PostgreSQL repair' "$($receipt.status); receipt: $receiptPath" }
}
# The cluster: made once (Sequence 8: UTF-8, the C.UTF-8 locale, data checksums, the log where LAPLACE_PGWAL says),
# run as the Windows service, its account over its directories; then the certificate, before ssl = on is declared (a
# server told to use TLS without one does not start), and the temporary tablespace when LAPLACE_PGTEMP names one.
function cluster {
    Part 'cluster'
    if (-not (Elevated 'cluster')) { return }
    if (-not (Test-Path "$PgBin\pg_ctl.exe")) { Say 'cluster' "FAILED: no server at $PgBin (deps)"; $failed.Add("cluster: no server at $PgBin"); return }
    foreach ($d in @((Split-Path $PgData), (Split-Path $PgWal), $PgTemp, $PgLogs)) { if ($d) { New-Item -ItemType Directory -Force $d | Out-Null } }
    if (-not (Test-Path (Join-Path $PgData 'PG_VERSION'))) {
        Attempt 'cluster' {
            $opts = @('-D', $PgData, '-U', 'postgres', '--encoding=UTF8', '--locale-provider=builtin', '--locale=C.UTF-8', '--data-checksums')
            if ($PgWal -ne (Join-Path $PgData 'pg_wal')) { $opts += "--waldir=$PgWal" }
            Exec "$PgBin\initdb.exe" $opts
            Say 'cluster' "initialised in $PgData, WAL in $PgWal"
        }
        if (-not (Test-Path (Join-Path $PgData 'PG_VERSION'))) { return }
    } else {
        $checksums = (& "$PgBin\pg_controldata.exe" $PgData 2>$null | Where-Object { $_ -match 'checksum version:\s+(\d+)' } | ForEach-Object { $Matches[1] })
        Say 'cluster' "$(Get-Content (Join-Path $PgData 'PG_VERSION')) in $PgData$(if ($checksums -eq '0') { '   no data checksums: enabled below (Sequence 8)' })"
    }
    Attempt 'rights' { GrantPg }

    # the service: registered once; a postmaster someone started by hand holds the data directory and is stopped first
    $svc = Get-Service -Name $PgService -ErrorAction SilentlyContinue
    if (-not $svc) {
        Attempt "service $PgService" {
            if (Test-Path (Join-Path $PgData 'postmaster.pid')) {
                & "$PgBin\pg_ctl.exe" -D $PgData -m fast -w -t 300 stop 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0 -or (Test-Path (Join-Path $PgData 'postmaster.pid'))) {
                    throw "The PostgreSQL server for $PgData did not stop cleanly. Its PID file and other processes were preserved."
                }
                Say 'hand-started server' 'stopped'
            }
            # pg_ctl registers the service as LocalSystem unless -U names the account (pg_ctl.c: register_username NULL);
            # a built-in account takes no password
            $out = & "$PgBin\pg_ctl.exe" register -N $PgService -U $PgAccount -D $PgData -S auto -w -t 1200 2>&1
            if ($LASTEXITCODE) { throw "pg_ctl register: $($out -join ' ')" }
            Say "service $PgService" "registered: automatic start, as $PgAccount"
        }
        $svc = Get-Service -Name $PgService -ErrorAction SilentlyContinue
    } else { Say "service $PgService" "$($svc.Status), start $($svc.StartType)" }
    if (-not $svc) { return }
    Set-PgServiceStartupTimeout (Get-PgRepairPlan)
    if ($svc.Status -ne 'Running') { Attempt "service $PgService start" { Start-Service -Name $PgService; Say "service $PgService" 'started' } }
    # after an unclean stop the server replays its log before it listens
    if (-not (PgWaitReady 120)) { Say 'cluster' 'FAILED: not accepting connections after two hours; see the log'; $failed.Add('cluster: not ready'); return }
    Say 'cluster' "accepting connections on ${PgHost}:$PgPort ($(PgSql 'SELECT version()'))"
    # data checksums (Sequence 8): a cluster made without them gets them in place, stopped, by pg_checksums
    if ((PgSql 'SHOW data_checksums') -ne 'on') {
        Attempt 'data checksums' { WithServerStopped 'data checksums' { Exec "$PgBin\pg_checksums.exe" @('--enable', '-D', $PgData) }; Say 'data checksums' "$(PgSql 'SHOW data_checksums') (pg_checksums --enable)" }
    } else { Say 'data checksums' 'on' }
    if ($PgTemp) { Attempt 'tablespace pgtemp' { if ((PgSql "SELECT count(*) FROM pg_tablespace WHERE spcname = 'pgtemp'") -ne '1') { PgSql "CREATE TABLESPACE pgtemp LOCATION '$($PgTemp -replace '\\', '/')'" | Out-Null }; Say 'tablespace pgtemp' $PgTemp } }
    if (-not (Test-Path (Join-Path $PgData 'server.crt'))) {
        Attempt 'certificate' {
            # Git's openssl is self-contained; the manifest's needs zlib's DLL from zlib's own prefix on the PATH (a missing
            # DLL is a dialog, not an exit code)
            $openssl = 'C:\Program Files\Git\usr\bin\openssl.exe'; $path = $env:PATH
            if (-not (Test-Path $openssl)) {
                $openssl = Get-ChildItem (Join-Path $Deps 'openssl') -Recurse -Filter openssl.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
                if (-not $openssl) { throw "no openssl (Git's, or the manifest's)" }
                $env:PATH = (@(Get-ChildItem (Join-Path $Deps 'zlib') -Directory | ForEach-Object { Join-Path $_.FullName 'bin' }) + $env:PATH) -join ';'
            }
            try { $out = & $openssl req -new -x509 -days 3650 -nodes -subj "/CN=$env:COMPUTERNAME" -keyout (Join-Path $PgData 'server.key') -out (Join-Path $PgData 'server.crt') 2>&1 }
            finally { $env:PATH = $path }
            if ($LASTEXITCODE -or -not (Test-Path (Join-Path $PgData 'server.crt'))) { throw "openssl: $($out -join ' ')" }
            $opSid = OperatorSid
            foreach ($f in 'server.key', 'server.crt') {
                $certGrants = @('/inheritance:r', '/grant', '*S-1-5-20:R', '/grant', '*S-1-5-32-544:F', '/grant', '*S-1-5-18:F')
                if ($opSid) { $certGrants += @('/grant', "*${opSid}:F") }
                & icacls.exe (Join-Path $PgData $f) @certGrants /Q | Out-Null
            }
            Say 'certificate' "self-signed, CN=$env:COMPUTERNAME, 3650 days, readable by $PgAccount"
        }
    } else { Say 'certificate' 'present' }
}
# The cluster dropped, for cluster to make again: the service stopped and deleted, and everything in its data
# directory, its log directory and its temporary directory removed. Every database on the server is lost, so it is
# never part of all, it asks for the data directory by name, and it does not run under an ingest.
function drop {
    Part 'drop'
    if (-not (Elevated 'drop')) { return }
    if ($env:LAPLACE_DROP -ne $PgData) { Say 'drop' "REFUSED: name the cluster to drop: `$env:LAPLACE_DROP = '$PgData'"; $failed.Add('drop: not named'); return }
    if (TuneIngesting) { Say 'drop' 'REFUSED: an ingest is running'; $failed.Add('drop: ingesting'); return }
    $svc = Get-Service -Name $PgService -ErrorAction SilentlyContinue
    if ($svc) { if ($svc.Status -ne 'Stopped') { Stop-Service -Name $PgService -Force }; & sc.exe delete $PgService | Out-Null; Say "service $PgService" 'stopped and deleted' }
    if (Test-Path (Join-Path $PgData 'postmaster.pid')) { & "$PgBin\pg_ctl.exe" -D $PgData -m fast -w -t 300 stop 2>&1 | Out-Null }
    foreach ($d in @($PgData, $PgWal, $PgTemp)) { if ($d -and (Test-Path $d)) { Remove-Item $d -Recurse -Force } }
    Say 'drop' "$PgData$(if ($PgWal -ne "$PgData\pg_wal") { ", $PgWal" })$(if ($PgTemp) { ", $PgTemp" }) removed: cluster makes the cluster again"
}
# Settings: every setting stated (tune-pg.ps1); the server itself says which changed and which need a restart. A
# restart is never made under a running ingest.
function settings {
    Part 'settings'
    if (-not (PgReady)) { Say 'settings' 'FAILED: the server is not accepting connections (cluster first)'; $failed.Add('settings: server not ready'); return }
    if ((Test-Path $PgCanon) -and (Admin)) { $env:PGPASSFILE = $PgCanon }   # elevated: the canonical password, whatever the operator's pgpass holds
    try {
        Attempt 'settings' {
            TuneApply | ForEach-Object { Say '  ' $_ }
            if (-not (TuneRestart)) { if (-not (Admin)) { Say 'restart' 'a setting read at start is pending: elevated, setup.ps1 settings' } }
            if (-not (TuneCheck)) { throw 'the live server does not match the declaration (the warnings above)' }
            Say 'settings' "$((TuneDeclared).Count) declared, none pending"
        }
        foreach ($line in (TunePsql "SELECT '  '||rpad(name, 46)||current_setting(name) FROM pg_settings WHERE name IN ('shared_buffers','effective_cache_size','work_mem','maintenance_work_mem','io_method','max_wal_size','wal_buffers','listen_addresses','ssl') ORDER BY name")) { $line }
    } finally { Remove-Item Env:PGPASSFILE -ErrorAction SilentlyContinue }
}
# Who may connect, and how (setup.sh: access). The whole pg_hba.conf, not a line added to whatever is there: the role
# on loopback by SSPI under the pg_ident map (the host authenticates the identities LAPLACE_PG_IDENTITIES names, the
# counterpart of Linux's peer socket: no password on this machine for the operator, IIS's pool or a service), postgres
# by scram on loopback, both by scram over TLS from $PgLan, nothing else. The
# role's password is one canonical copy, administrators only, adopted from the operator's pgpass when it is the one
# the server accepts, made when none is, and written into the operator's %APPDATA%\postgresql\pgpass.conf, which libpq
# reads for psql and the laplace program. Only this host's line for the role is replaced there: the operator's lines
# for other hosts (hart-server's database) are theirs and stay. Never printed. The firewall admits the server's port (LAPLACE_PGPORT) from $PgLan.
function PgWorks([string]$pw) {
    $previousPassword = $env:PGPASSWORD
    try { $env:PGPASSWORD = $pw; $r = & "$PgBin\psql.exe" -X -w -h $PgHost -p $PgPort -U $PgRole -d postgres -Atq -c 'SELECT 1' 2>$null; "$r" -eq '1' }
    finally { $env:PGPASSWORD = $previousPassword }
}
function PgPassOf([string]$file) { if (Test-Path $file) { foreach ($l in Get-Content $file) { $f = $l -split ':'; if ($f.Count -ge 5 -and $f[3] -eq $PgRole -and $f[0] -in '*', 'localhost', '127.0.0.1', '::1', $env:COMPUTERNAME) { return ($f[4..($f.Count - 1)] -join ':') } } }; $null }
function access {
    Part 'access'
    if (-not (Elevated 'access')) { return }
    if (-not (PgReady)) { Say 'access' 'FAILED: the server is not accepting connections (cluster first)'; $failed.Add('access: server not ready'); return }
    $operatorDeclaration=Join-Path $OpsRoot ('installation/'+$env:COMPUTERNAME.ToLowerInvariant()+'-operator.json')
    if(Test-Path -LiteralPath $operatorDeclaration){
        $operatorConfiguration=Get-Content -LiteralPath $operatorDeclaration -Raw | ConvertFrom-Json -AsHashtable
        if(@($operatorConfiguration.targets | Where-Object {$_['authentication'] -eq 'sspi'}).Count){
            & "$OpsRoot/installation/windows-operator-access.ps1" -Configuration $operatorDeclaration
            return
        }
    }
    $operator = Join-Path $env:APPDATA 'postgresql\pgpass.conf'
    Attempt "role $PgRole" {
        if ((PgSql "SELECT count(*) FROM pg_roles WHERE rolname = '$PgRole'") -ne '1') { PgSql "CREATE ROLE $PgRole LOGIN SUPERUSER" | Out-Null }
        $pw = PgPassOf $PgCanon; $how = "password in $PgCanon"
        # the installation's password is the deployment target's (LAPLACE_PEER): read from its operator's pgpass over SSH,
        # given to the role here when the role does not already accept it. Never printed.
        if ($env:LAPLACE_PEER) {
            $sshOpts = @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10'); if ($env:LAPLACE_PEER_KEY -and (Test-Path $env:LAPLACE_PEER_KEY)) { $sshOpts += '-i', $env:LAPLACE_PEER_KEY }
            $peer = (& ssh.exe @sshOpts $env:LAPLACE_PEER "grep ':${PgRole}:' ~/.pgpass | head -1 | cut -d: -f5-" 2>$null | Select-Object -First 1)
            if ($peer) {
                $peer = $peer.Trim()
                if (-not (PgWorks $peer)) { PgSql "ALTER ROLE $PgRole PASSWORD '$($peer -replace "'", "''")'" | Out-Null }
                $pw = $peer; $how = "password the installation's, from $($env:LAPLACE_PEER)"
                New-Item -ItemType Directory -Force (Split-Path $PgCanon) | Out-Null
                Set-Content -Path $PgCanon -Value "*:${PgPort}:*:${PgRole}:$pw" -Encoding ascii -NoNewline
                & icacls.exe $PgCanon /inheritance:r /grant '*S-1-5-32-544:F' /Q | Out-Null
            } else { Say "role $PgRole" "$($env:LAPLACE_PEER) did not answer with a password for ${PgRole}: this machine's own is kept" }
        }
        if (-not $pw -or -not (PgWorks $pw)) {
            $keep = $pw; $pw = $null
            $c = PgPassOf $operator; if ($c -and (PgWorks $c)) { $pw = $c; $how = "password adopted from $operator" }
            # a cluster made again has the role without a password: it is given the canonical one, so no client's copy breaks
            if (-not $pw -and $keep) { $pw = $keep; PgSql "ALTER ROLE $PgRole PASSWORD '$($pw -replace "'", "''")'" | Out-Null; $how = "password from $PgCanon" }
            if (-not $pw) { $pw = [Convert]::ToBase64String((1..24 | ForEach-Object { Get-Random -Maximum 256 })) -replace '[/+=]', ''; $pw = $pw.Substring(0, [math]::Min(32, $pw.Length)); PgSql "ALTER ROLE $PgRole PASSWORD '$pw'" | Out-Null; $how = 'password made' }
            New-Item -ItemType Directory -Force (Split-Path $PgCanon) | Out-Null
            Set-Content -Path $PgCanon -Value "*:${PgPort}:*:${PgRole}:$pw" -Encoding ascii -NoNewline
            & icacls.exe $PgCanon /inheritance:r /grant '*S-1-5-32-544:F' /Q | Out-Null
        }
        # the operator's pgpass: this host's line for the role replaced, every other line kept
        New-Item -ItemType Directory -Force (Split-Path $operator) | Out-Null
        $rest = @(); if (Test-Path $operator) { $rest = @(Get-Content $operator | Where-Object { $f = $_ -split ':'; $f.Count -lt 5 -or $f[3] -ne $PgRole -or $f[0] -notin '*', 'localhost', '127.0.0.1', '::1', $env:COMPUTERNAME }) }
        Set-Content -Path $operator -Value (@($rest) + "*:${PgPort}:*:${PgRole}:$pw") -Encoding ascii
        $pw = $null
        Say "role $PgRole" "$how; written to $operator"
    }
    Attempt 'role postgres' { if ((PgSql "SELECT count(*) FROM pg_roles WHERE rolname = 'postgres'") -ne '1') { PgSql 'CREATE ROLE postgres LOGIN SUPERUSER' | Out-Null }; Say 'role postgres' 'existing credential retained; a new role requires an explicitly provisioned credential' }
    Attempt 'pg_hba.conf' {
        $hba = @(
            "# Laplace (setup.ps1). Loopback: $PgRole by SSPI under the map (pg_ident.conf), postgres by scram. The network: scram over TLS from $PgLan. Nothing else.",
            ('{0,-10}{1,-6}{2,-10}{3,-20}{4}' -f 'host',      'all', $PgRole,    '127.0.0.1/32', "sspi map=$PgRole include_realm=0"),
            ('{0,-10}{1,-6}{2,-10}{3,-20}{4}' -f 'host',      'all', $PgRole,    '::1/128',      "sspi map=$PgRole include_realm=0"),
            ('{0,-10}{1,-6}{2,-10}{3,-20}{4}' -f 'hostssl',   'all', $PgRole,    $PgLan,         'scram-sha-256'),
            ('{0,-10}{1,-6}{2,-10}{3,-20}{4}' -f 'host',      'all', 'postgres', '127.0.0.1/32', 'scram-sha-256'),
            ('{0,-10}{1,-6}{2,-10}{3,-20}{4}' -f 'host',      'all', 'postgres', '::1/128',      'scram-sha-256'),
            ('{0,-10}{1,-6}{2,-10}{3,-20}{4}' -f 'hostssl',   'all', 'postgres', $PgLan,         'scram-sha-256'),
            ('{0,-10}{1,-6}{2,-10}{3,-20}{4}' -f 'hostnossl', 'all', 'all',      '0.0.0.0/0',    'reject')
        ) -join "`n"
        $file = Join-Path $PgData 'pg_hba.conf'
        if ((Test-Path $file) -and ((Get-Content $file -Raw) -replace "`r`n", "`n").TrimEnd() -eq $hba) { Say 'pg_hba.conf' 'as declared'; return }
        if (Test-Path $file) { Copy-Item $file "$file.before" -Force }
        Set-Content -Path $file -Value ($hba + "`n") -Encoding ascii -NoNewline
        PgSql 'SELECT pg_reload_conf()' | Out-Null
        Say 'pg_hba.conf' 'written'
    }
    Attempt 'pg_ident.conf' {
        # the map: each identity LAPLACE_PG_IDENTITIES names, as SSPI presents it with the realm stripped, is the role
        $ident = @("# Laplace (setup.ps1). The identities this host authenticates as $PgRole (LAPLACE_PG_IDENTITIES).") +
            @(($env:LAPLACE_PG_IDENTITIES -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object { '{0,-10}{1,-24}{2}' -f $PgRole, ('"' + $_ + '"'), $PgRole })
        $ident = $ident -join "`n"
        $file = Join-Path $PgData 'pg_ident.conf'
        if ((Test-Path $file) -and ((Get-Content $file -Raw) -replace "`r`n", "`n").TrimEnd() -eq $ident) { Say 'pg_ident.conf' 'as declared'; return }
        if (Test-Path $file) { Copy-Item $file "$file.before" -Force }
        Set-Content -Path $file -Value ($ident + "`n") -Encoding ascii -NoNewline
        PgSql 'SELECT pg_reload_conf()' | Out-Null
        Say 'pg_ident.conf' 'written'
    }
    Attempt 'firewall' {
        # any enabled inbound allow rule for the server's port admits it already (an earlier install's rule counts); one is made only when none exists
        $have = @(Get-NetFirewallRule -Direction Inbound -Action Allow -Enabled True -ErrorAction SilentlyContinue | Where-Object { ($_ | Get-NetFirewallPortFilter).LocalPort -contains $PgPort })
        if ($have.Count) { Say 'firewall' "$PgPort/tcp admitted by: $(($have | ForEach-Object DisplayName) -join ', ')" }
        else { New-NetFirewallRule -DisplayName 'Laplace PostgreSQL' -Direction Inbound -Protocol TCP -LocalPort $PgPort -RemoteAddress $PgLan -Action Allow -Profile Any | Out-Null; Say 'firewall' "$PgPort/tcp from $PgLan allowed" }
    }
    PgSql "SELECT '  '||rpad(type, 10)||rpad(array_to_string(user_name, ','), 10)||rpad(coalesce(address, '-'), 18)||auth_method||coalesce('   '||error, '') FROM pg_hba_file_rules ORDER BY rule_number"
}
# What the machine is now: the server, where it listens, and both legs of the cross-OS check, each as the operator
# with the operator's pgpass: this database from the network, and the database LAPLACE_CONNINFO names (hart-server's,
# when it is set to it).
function report {
    Part 'report'
    $svc = Get-Service -Name $PgService -ErrorAction SilentlyContinue
    Say "service $PgService" $(if ($svc) { "$($svc.Status), start $($svc.StartType)" } else { 'MISSING (cluster)' })
    if (-not (Test-Path "$PgBin\postgres.exe")) { Say 'server' "MISSING: no server at $PgBin (deps)"; return }
    Say 'server' "$(& "$PgBin\postgres.exe" --version)   $(if (PgReady) { 'accepting connections' } else { 'NOT ACCEPTING CONNECTIONS' })"
    if (-not (PgReady)) { return }
    Say 'listening' ((Get-NetTCPConnection -LocalPort $PgPort -State Listen -ErrorAction SilentlyContinue | ForEach-Object { "$($_.LocalAddress):$PgPort" } | Sort-Object -Unique) -join ' ')
    $net = ($PgLan -split '/')[0] -replace '\.\d+$', ''
    $addr = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -like "$net.*" } | Select-Object -First 1).IPAddress
    $probe = "SELECT 'connected to '||coalesce(host(inet_server_addr()), 'local')||' as '||current_user||', TLS '||coalesce((SELECT version FROM pg_stat_ssl WHERE pid = pg_backend_pid()), 'off')"
    # Access is what the access part declared: with an SSPI operator declaration (windows-operator-access.ps1), the
    # operator's libpq service and Windows identity, TLS verified; otherwise the role and password of the legacy layout.
    $operatorDeclaration = Join-Path $OpsRoot ('installation/'+$env:COMPUTERNAME.ToLowerInvariant()+'-operator.json')
    $operator = $null
    if (Test-Path -LiteralPath $operatorDeclaration) {
        $declared = Get-Content -LiteralPath $operatorDeclaration -Raw | ConvertFrom-Json -AsHashtable
        $operator = @($declared.targets | Where-Object { $_['authentication'] -eq 'sspi' }) | Select-Object -First 1
    }
    $saved = @{ PGSERVICEFILE = $env:PGSERVICEFILE; OPENSSL_CONF = $env:OPENSSL_CONF }
    try {
        if ($operator) {
            $env:PGSERVICEFILE = Join-Path $declared.state 'operator-services.conf'
            $env:OPENSSL_CONF = Join-Path $declared.state 'operator-openssl.cnf'
            $conn = "service=$($operator.service) dbname=postgres"
            $who = "as $($declared.role) ($($operator.authentication_identity))"
            $lan = if ($addr) { "service=$($operator.service) hostaddr=$addr dbname=postgres" }
        } else {
            $conn = "host=$PgHost port=$PgPort user=$PgRole dbname=postgres"
            $who = "as $PgRole"
            $lan = if ($addr) { "host=$addr port=$PgPort user=$PgRole dbname=postgres sslmode=require" }
        }
        Say 'PostGIS' "$(& "$PgBin\psql.exe" -X $conn -Atq -c "SELECT coalesce(default_version, 'NOT INSTALLED') FROM pg_available_extensions WHERE name = 'postgis'" 2>&1 | Select-Object -Last 1)"
        Say "this database, $who" "$(& "$PgBin\psql.exe" -X $conn -Atq -c $probe 2>&1 | Select-Object -Last 1)"
        if ($lan) { Say "this database from $PgLan, $who" "$(& "$PgBin\psql.exe" -X $lan -Atq -c $probe 2>&1 | Select-Object -Last 1)" }
        else { Say "this database from $PgLan" 'this machine has no address on it' }
        if (-not $operator) {
            $r = & "$PgBin\psql.exe" -X ($env:LAPLACE_CONNINFO -replace 'dbname=\S+', 'dbname=postgres') -Atq -c $probe 2>&1 | Select-Object -Last 1
            Say "LAPLACE_CONNINFO ($(($env:LAPLACE_CONNINFO -split ' ' | Where-Object { $_ -like 'host=*' }) -replace '^host='))" "$r"
        }
        foreach ($line in (& "$PgBin\psql.exe" -X $conn -Atq -c "SELECT '  '||rpad(name, 46)||current_setting(name) FROM pg_settings WHERE name IN ('shared_buffers','effective_cache_size','max_wal_size','listen_addresses','ssl','data_checksums') ORDER BY name" 2>$null)) { $line }
    } finally {
        foreach ($name in $saved.Keys) { if ($null -eq $saved[$name]) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue } else { Set-Item "Env:$name" $saved[$name] } }
    }
    ''; 'next: the Laplace builds (README: Windows); the Linux machine: sudo ./setup.sh, ./deploy.sh'
}

# ------------------------------------------------------------------------------------------------------ the desktop's own
# What this machine is besides a Laplace host: none of these is part of all, each is named to be run, and each takes
# status (setup.ps1 backup status) to report without changing anything.

# The deployment target's shares (setup.sh shares there), as this machine reaches them: by UNC path, with the
# operator's Credential Manager entry for the host. Checked and reported, never made: no drive letter is mapped and no
# credential is stored here, and the Explorer locations and mappings the operator made are theirs. A check that fails
# says what to do. The password is never read, printed or written: cmdkey asks for it.
function network {
    Part 'network'
    $argsForNetwork = @('-NoProfile', '-File', "$OpsRoot\network.ps1")
    if ($Status) { $argsForNetwork += '-Check' }
    & pwsh.exe @argsForNetwork
    if ($LASTEXITCODE) { $failed.Add('network: DNS configuration or resolution failed') }
}
function shares {
    Part 'shares'
    $server = $env:LAPLACE_SHARE_HOST; $user = $env:LAPLACE_SHARE_USER
    # cmdkey /list: a Target line, then Type and User; only this host's own entry counts (not hart-server.lan's)
    $entry = $null; $lines = @(& cmdkey.exe /list 2>$null)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^\s*Target:\s*(Domain:target=)?$([regex]::Escape($server))\s*$") {
            $u = ($lines[($i + 1)..([math]::Min($i + 3, $lines.Count - 1))] | Where-Object { $_ -match '^\s*User:\s*(.+)$' } | Select-Object -First 1) -replace '^\s*User:\s*', ''
            $entry = "$($lines[$i].Trim() -replace '^Target:\s*', ''), user $u"; break
        }
    }
    if ($entry) { Say "credential for $server" "present: $entry" }
    else { Say "credential for $server" "MISSING: cmdkey /add:$server /user:$user /pass   (it asks for the SMB password)"; $failed.Add("shares: no credential for $server") }
    $tcp = [Net.Sockets.TcpClient]::new()
    try { $up = $tcp.ConnectAsync($server, 445).Wait(3000) } catch { $up = $false } finally { $tcp.Dispose() }
    if (-not $up) { Say "${server}:445" "DOES NOT ANSWER: is it up, and are its shares served (on $server, sudo ./setup.sh shares)?"; $failed.Add("shares: ${server}:445 does not answer"); return }
    Say "${server}:445" 'answers'
    foreach ($share in ($env:LAPLACE_SHARES -split ',' | ForEach-Object Trim | Where-Object { $_ })) {
        $unc = "\\$server\$share"
        if (Test-Path -LiteralPath $unc) { Say $unc 'answers' }
        else {
            Say $unc "DOES NOT ANSWER: $(if ($entry) { "the credential may be wrong (cmdkey /delete:$server, then cmdkey /add:$server /user:$user /pass), or the share is not served (on $server, sudo ./setup.sh shares)" } else { 'add the credential (above)' })"
            $failed.Add("shares: $unc does not answer")
        }
    }
    if (Admin) { Say 'checked from' 'an elevated shell; Explorer uses the same credential from the normal one' }
}
# The GPU services (LAPLACE_GPU_SERVICES, llama.cpp under NSSM) are started, stopped and queried by the operator without
# elevation (chess\chess-gpu.ps1): one allow ACE for the operator's own SID (start RP, stop WP, query status LC,
# interrogate LO) appended to each service's DACL; nothing else in it changes. Already granted is known by the SID,
# never by the ACE's text, since Windows writes the rights in its own order. Each change prints the SDDL before and
# after; sc.exe sdset <service> "<before>" undoes it.
function services {
    Part 'services'
    if (-not $Status -and -not (Elevated 'services')) { return }
    $me = [Security.Principal.WindowsIdentity]::GetCurrent(); $sid = $me.User.Value
    foreach ($svc in ($env:LAPLACE_GPU_SERVICES -split ',' | ForEach-Object Trim | Where-Object { $_ })) {
        Attempt "service $svc" {
            if (-not (Get-Service -Name $svc -ErrorAction SilentlyContinue)) { Say $svc 'NOT ON THIS MACHINE: nothing to grant'; return }
            $sd = ((& sc.exe sdshow $svc) -join '').Trim()
            if ($LASTEXITCODE) { throw "sc sdshow: $sd" }
            $held = @([regex]::Matches($sd, "\(A;;([A-Z]*);;;$([regex]::Escape($sid))\)") | ForEach-Object { $r = $_.Groups[1].Value; for ($k = 0; $k -lt $r.Length; $k += 2) { $r.Substring($k, 2) } })
            $lack = @('LC', 'RP', 'WP', 'LO' | Where-Object { $held -notcontains $_ })
            if (-not $lack.Count) { Say $svc "already granted to $($me.Name)"; return }
            if ($Status) { Say $svc "NOT GRANTED to $($me.Name) ($($lack -join '')): elevated, setup.ps1 services"; return }
            $i = $sd.IndexOf('S:'); $ace = "(A;;LCRPWPLO;;;$sid)"
            $new = if ($i -ge 0) { $sd.Insert($i, $ace) } else { $sd + $ace }
            $out = & sc.exe sdset $svc $new; if ($LASTEXITCODE) { throw "sc sdset: $($out -join ' ')" }
            Say $svc "granted to $($me.Name)"; "    before: $sd"; "    after:  $(((& sc.exe sdshow $svc) -join '').Trim())"
        }
    }
}
# The inbound rules this machine's endpoints need, each one named rule, TCP, from the one client that calls it
# (LAPLACE_FIREWALL: name=port@client;...): the engine endpoint (laplace-uci behind LaplaceEngines) for the deployment
# target. Created when missing, corrected when its port, client or profile differs, otherwise left alone.
function firewall {
    Part 'firewall'
    if (-not $Status -and -not (Elevated 'firewall')) { return }
    foreach ($spec in ($env:LAPLACE_FIREWALL -split ';' | ForEach-Object Trim | Where-Object { $_ })) {
        if ($spec -notmatch '^(?<name>[^=]+)=(?<port>\d+)@(?<client>[^@]+)$') { Say $spec 'UNREADABLE: name=port@client'; $failed.Add("firewall: $spec"); continue }
        $name = "Laplace-$($Matches.name)"; $port = $Matches.port; $client = $Matches.client
        Attempt "rule $name" {
            $r = Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue
            if (-not $r) {
                if ($Status) { Say $name "MISSING: TCP $port from $client (elevated, setup.ps1 firewall)"; return }
                New-NetFirewallRule -Name $name -DisplayName "Laplace $($Matches.name) $port from $client" -Direction Inbound -Protocol TCP `
                    -LocalPort $port -RemoteAddress $client -Action Allow -Profile Private | Out-Null
                Say $name "made: TCP $port from $client, private networks"; return
            }
            $p = $r | Get-NetFirewallPortFilter; $a = $r | Get-NetFirewallAddressFilter
            $ok = $r.Enabled -eq 'True' -and $r.Direction -eq 'Inbound' -and $r.Action -eq 'Allow' -and $p.Protocol -eq 'TCP' -and "$($p.LocalPort)" -eq $port `
                -and "$($a.RemoteAddress)" -eq $client -and "$($r.Profile)" -eq 'Private'
            if ($ok) { Say $name "as declared: TCP $port from $client"; return }
            if ($Status) { Say $name "DIFFERS (port $($p.LocalPort), from $($a.RemoteAddress), $($r.Profile)): elevated, setup.ps1 firewall"; return }
            Set-NetFirewallRule -Name $name -Enabled True -Direction Inbound -Action Allow -Profile Private
            $r | Get-NetFirewallPortFilter | Set-NetFirewallPortFilter -Protocol TCP -LocalPort $port
            $r | Get-NetFirewallAddressFilter | Set-NetFirewallAddressFilter -RemoteAddress $client
            Say $name "corrected: TCP $port from $client, private networks"
        }
    }
}
# The copy-off of this machine's drives to the deployment target (backup\: jobs.psd1 says what goes where; copyoff.ps1
# hashes and copies a set; run.ps1 runs every set), run by the scheduled task LAPLACE_BACKUP_TASK as the operator:
# interactive, not elevated, with no time limit, one instance at a time, no trigger (Start-ScheduledTask runs it), in a
# headless console. The task is registered when missing and updated when it differs from the declaration, but never
# while it runs: a running copy-off is not cut off, and the part says to run again when it is done. Then the state:
# the task, its run, the last job lines of each set's log and the manifests written.
function backup {
    Part 'backup'
    $task = $env:LAPLACE_BACKUP_TASK; $logs = $env:LAPLACE_BACKUP_LOGS
    $argv = "--headless pwsh.exe -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $OpsRoot 'backup\run.ps1')`""
    $conf = $null
    . "$OpsRoot\backup\config.ps1"
    try { $conf = Read-BackupConfiguration $env:LAPLACE_BACKUP_JOBS }
    catch { Say 'jobs' "FAILED: $($env:LAPLACE_BACKUP_JOBS): $($_.Exception.Message)"; $failed.Add("backup: $($env:LAPLACE_BACKUP_JOBS) does not read") }
    foreach ($s in @($conf.Sets)) { $held = @($s.Jobs | Where-Object { $_.n -like 'Models-*' }).Count; Say "set $($s.Name)" "$(@($s.Jobs).Count) jobs to $($s.Inbox)$(if ($held) { "; $held Models-* on hold without -Models" })" }
    $t = Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
    $drift = @(
        if (-not $t) { 'missing' } else {
            $a = @($t.Actions)
            if ($a.Count -ne 1 -or $a[0].Execute -ne 'conhost.exe' -or $a[0].Arguments -ne $argv) { "runs $($a[0].Execute) $($a[0].Arguments)" }
            if ((($t.Principal.UserId -split '\\')[-1]) -ne $env:USERNAME) { "as $($t.Principal.UserId)" }
            if ("$($t.Principal.LogonType)" -ne 'Interactive') { "logon $($t.Principal.LogonType)" }
            if ("$($t.Principal.RunLevel)" -ne 'Limited') { "run level $($t.Principal.RunLevel)" }
            if ($t.Settings.ExecutionTimeLimit -ne 'PT0S') { "time limit $($t.Settings.ExecutionTimeLimit)" }
            if ("$($t.Settings.MultipleInstances)" -ne 'IgnoreNew') { "instances $($t.Settings.MultipleInstances)" }
            $trig = @($t.Triggers | Where-Object { $_ }); if ($trig.Count) { "$($trig.Count) trigger(s)" }
        })
    if (-not $drift.Count) { Say "task $task" 'as declared' }
    elseif ($Status) { Say "task $task" "DIFFERS: $($drift -join '; '): setup.ps1 backup" }
    elseif ($t -and "$($t.State)" -eq 'Running') { Say "task $task" "DIFFERS ($($drift -join '; ')), and it is running: not changed; setup.ps1 backup again when it is done" }
    else {
        Attempt "task $task" {
            New-Item -ItemType Directory -Force $logs | Out-Null
            $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
            $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
            Register-ScheduledTask -TaskName $task -Action (New-ScheduledTaskAction -Execute 'conhost.exe' -Argument $argv) -Principal $principal -Settings $settings -Force | Out-Null
            Say "task $task" $(if ($t) { "updated (was: $($drift -join '; '))" } else { 'registered: Start-ScheduledTask runs it' })
        }
    }
    $t = Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
    if ($t) {
        $info = Get-ScheduledTaskInfo -TaskName $task
        Say "task $task" $(if ($info.LastTaskResult -eq 0x41303) { "$($t.State); never run" } else { "{0}; last run {1:s}, result 0x{2:X}" -f $t.State, $info.LastRunTime, $info.LastTaskResult })
        Say 'runs' "$(@($t.Actions)[0].Execute) $(@($t.Actions)[0].Arguments)"
    }
    $pidFile = Join-Path $logs 'run.pid'
    if (Test-Path $pidFile) { $p = Get-Process -Id ([int](Get-Content $pidFile)) -ErrorAction SilentlyContinue; Say 'run.pid' "$(Get-Content $pidFile)$(if ($p) { ", running since $('{0:s}' -f $p.StartTime)" } else { ', not running' })" }
    # the job lines of each set's log: neither progress, nor what could not be read, nor git's warnings
    foreach ($f in @(Get-ChildItem $logs -Filter 'run*.log' -File -ErrorAction SilentlyContinue)) {
        Say $f.Name ("{0:s}" -f $f.LastWriteTime)
        Get-Content $f.FullName | Where-Object { $_ -and $_ -notmatch '^\S+\s+[\d,]+/[\d,]+\s+\d+s$' -and $_ -notmatch 'unreadable|^warning:' } | Select-Object -Last 6 | ForEach-Object { "      $_" }
    }
    foreach ($s in @($conf.Sets)) {
        $dir = Join-Path $(if ($s.Logs) { Join-Path $logs $s.Logs } else { $logs }) 'manifests'
        foreach ($m in @(Get-ChildItem $dir -Filter '*.tsv' -File -ErrorAction SilentlyContinue)) { Say "manifest $($s.Name) $($m.BaseName)" "$((Get-Content $m.FullName -Tail 1) -replace '^# total ', '')   $('{0:s}' -f $m.LastWriteTime)" }
        foreach ($m in @(Get-ChildItem $dir -Filter '*.part' -File -ErrorAction SilentlyContinue)) { Say "manifest $($s.Name) $($m.Name)" "being written: $((Get-Content $m.FullName | Measure-Object -Line).Lines) rows" }
    }
}
