# Pure verification helpers. Provider tuples establish identity; user_id is a
# database-local reference resolved from that tuple, never installation authority.
function Resolve-PlatformAdministratorBindings {
    param([object[]]$Expected,[object[]]$Bindings,$OwnerPolicy)
    if(-not $Expected.Count -or $Expected.Count -gt 16){throw 'Declare between one and sixteen administrator bindings.'}
    if($Bindings.Count -ge 50001){throw 'Application identity readback exceeds its bounded result limit.'}
    if($null -ne $OwnerPolicy -and ($OwnerPolicy.version -ne 1 -or $null -eq $OwnerPolicy.owners)){throw 'Invalid installation owner policy contract.'}
    $resolved=@()
    foreach($person in $Expected){
        if($person.provider -cnotin 'google','microsoft' -or -not $person.issuer -or -not $person.subject){throw 'An administrator declaration has an invalid provider binding.'}
        $duplicates=@($Expected | Where-Object {$_.provider -ceq $person.provider -and $_.issuer -ceq $person.issuer -and $_.subject -ceq $person.subject})
        if($duplicates.Count -ne 1){throw 'Administrator declarations contain a duplicate provider binding.'}
        $match=@($Bindings | Where-Object {$_.provider -ceq $person.provider -and $_.issuer -ceq $person.issuer -and $_.subject -ceq $person.subject})
        if($match.Count -ne 1){throw 'An administrator requires exactly one stored provider binding.'}
        $binding=$match[0]
        $parsed=[Guid]::Empty
        if(-not [Guid]::TryParseExact([string]$binding.user_id,'D',[ref]$parsed) -or $parsed -eq [Guid]::Empty){throw 'Stored administrator reference is invalid.'}
        $policyMatches=@($OwnerPolicy.owners | Where-Object {$_.provider -ceq $person.provider -and $_.issuer -ceq $person.issuer -and $_.subject -ceq $person.subject})
        if($policyMatches.Count -gt 1){throw 'Installation policy contains an ambiguous provider binding.'}
        $isOwner=$policyMatches.Count -eq 1
        if($binding.role -cne 'administrator' -or $binding.audited -cne $true){throw 'A stored administrator requires an audited administrator grant.'}
        if(-not $isOwner -and -not $binding.last_login_at){throw 'An ordinary administrator requires a previously authenticated binding.'}
        $resolved += [pscustomobject]@{user_id=$parsed.ToString('D');provider=$person.provider;installation_owner=$isOwner;login_observed=[bool]$binding.last_login_at}
    }
    return $resolved
}

function Test-PlatformAdministratorReadback {
    param([object[]]$Resolved,[object[]]$People,[object[]]$Providers)
    foreach($person in $Resolved){
        $match=@($People | Where-Object {$_.userId -eq $person.user_id})
        if($match.Count -ne 1 -or $match[0].role -cne 'administrator' -or $match[0].providers -cnotcontains $person.provider){throw 'Serving administrator readback does not match the current stored binding.'}
        if($person.installation_owner -and $match[0].installationOwner -cne $true){throw 'Serving application has not recognized the configured installation owner.'}
        if(@($Providers | Where-Object id -CEQ $person.provider).Count -ne 1){throw 'Serving application does not expose the declared OAuth provider.'}
    }
}
