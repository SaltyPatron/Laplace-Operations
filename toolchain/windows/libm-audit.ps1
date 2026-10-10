# Every DLL and EXE under the given directories, checked for libm functions imported from libmmd (Intel's libm). Only
# exact operations may come from it (determinism.tsv); a transcendental function imported from it means a link that
# did not end with laplace-math. Exit 1 when any binary imports one. Run from the oneAPI dev shell (dumpbin).
#   toolchain\windows\libm-audit.ps1 D:\Libraries\postgresql\18.6\bin, D:\Libraries\postgresql\18.6\lib   (one array)
param([Parameter(Mandatory)][string[]]$Directories)

$exact = '^(sqrtf?|fmaf?|roundf?|l?lroundf?|l?rintf?|nearbyintf?|truncf?|floorf?|ceilf?|fminf?|fmaxf?|fabsf?|copysignf?|nanf?|ldexpf?|scalbnf?|frexpf?|modff?|fmodf?|remainderf?|remquof?|nextafterf?|nexttowardf?|ilogbf?|logbf?|__isnanf?|__isinff?|__finitef?|__signbitf?|__fpclassifyf?|fe\w+)$'
$failed = 0
$count = 0
foreach ($dir in $Directories) {
    foreach ($f in Get-ChildItem -Path "$dir\*" -File -Include *.dll, *.exe) {
        if ($f.Name -match '^libmmd') { continue }
        $count++
        $from = ''
        $bad = foreach ($line in (& dumpbin.exe /nologo /imports $f.FullName)) {
            if ($line -match '^\s+(\S+\.dll)\s*$') { $from = $Matches[1].ToLowerInvariant() }
            elseif ($line -match '^\s+Summary') { $from = '' }
            elseif ($from -eq 'libmmd.dll' -and $line -match '^\s+[0-9A-F]+\s+(\S+)\s*$' -and $Matches[1] -notmatch $exact) { $Matches[1] }
        }
        if ($bad) { $failed++; '{0}: {1}' -f $f.FullName, ($bad -join ', ') }
    }
}
'{0} binaries, {1} importing libm functions from libmmd' -f $count, $failed
exit [int]($failed -gt 0)
