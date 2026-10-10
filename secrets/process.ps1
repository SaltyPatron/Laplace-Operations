function Invoke-Program([string]$Program, [string[]]$Arguments, [string]$InputText = '') {
    $info = [Diagnostics.ProcessStartInfo]::new($Program)
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($info)
    $output = $process.StandardOutput.ReadToEndAsync(); $errorText = $process.StandardError.ReadToEndAsync()
    $process.StandardInput.Write($InputText); $process.StandardInput.Close()
    if (-not $process.WaitForExit(60000)) { $process.Kill($true); throw "$Program timed out" }
    $result = $output.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0) { throw "$Program failed: $($errorText.GetAwaiter().GetResult())" }
    $result
}
