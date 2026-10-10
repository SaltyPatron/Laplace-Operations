# Resolve backup paths from the same machine declaration as builds and deployment.
function Read-BackupConfiguration([string]$Path) {
    function Expand-BackupValue($value) {
        if ($value -is [string]) {
            $expanded = [Environment]::ExpandEnvironmentVariables($value)
            if ($expanded -match '%[A-Za-z_][A-Za-z0-9_]*%') { throw "Unresolved backup path: $value" }
            return $expanded
        }
        if ($value -is [System.Collections.IDictionary]) {
            $result = @{}
            foreach ($key in $value.Keys) { $result[$key] = Expand-BackupValue $value[$key] }
            return $result
        }
        if ($value -is [array]) { return ,@($value | ForEach-Object { Expand-BackupValue $_ }) }
        return $value
    }
    Expand-BackupValue (Import-PowerShellDataFile -LiteralPath $Path)
}
