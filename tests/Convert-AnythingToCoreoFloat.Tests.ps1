#requires -Version 7.0
$ErrorActionPreference = 'Stop'

$converterScript = Join-Path $PSScriptRoot '..\tools\Convert-AnythingToCoreoFloat.ps1'
$powerShell = (Get-Command pwsh -ErrorAction Stop).Source
$selfTestOutput = @(& $powerShell -NoLogo -NoProfile -File $converterScript -StreamSelfTest 2>&1)
$selfTestExitCode = $LASTEXITCODE
$selfTestOutput | ForEach-Object { Write-Output $_ }
if ($selfTestExitCode -ne 0) {
    throw "COREO stream self-tests failed with exit code $selfTestExitCode."
}

function Invoke-CoreoStreamProcess {
    param([byte[]]$InputBytes)

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $powerShell
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @(
        '-NoLogo', '-NoProfile', '-File', $converterScript,
        '-StdinStdout', '-FramesPerBlock', '2'
    )) {
        $startInfo.ArgumentList.Add([string]$argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw 'The PowerShell stream converter did not start.'
        }

        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.BaseStream.Write($InputBytes, 0, $InputBytes.Length)
        $process.StandardInput.Close()

        if (-not $process.WaitForExit(15000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw 'The PowerShell stdin/stdout converter timed out.'
        }

        $stdout = [IO.MemoryStream]::new()
        $process.StandardOutput.BaseStream.CopyTo($stdout)
        $stderr = $stderrTask.GetAwaiter().GetResult()
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Output = $stdout.ToArray()
            Error = $stderr
        }
    }
    finally {
        if (-not $process.HasExited) {
            $process.Kill($true)
            $process.WaitForExit()
        }
        $process.Dispose()
    }
}

$sourceSamples = [single[]]@(
    0.125, -0.25,
    0.5, 0.25,
    -0.5, -0.125
)
$expectedSamples = [single[]]@(
    0.5, 0.125, -0.125, 0.25,
    -0.5, -0.25, -0.5, -0.25,
    -0.125, 0.25, 0.5, 0.125
)
$sourceBytes = [byte[]]::new($sourceSamples.Length * 4)
[Buffer]::BlockCopy($sourceSamples, 0, $sourceBytes, 0, $sourceBytes.Length)

$result = Invoke-CoreoStreamProcess -InputBytes $sourceBytes
if ($result.ExitCode -ne 0) {
    throw "The PowerShell stdin/stdout converter failed with exit $($result.ExitCode): $($result.Error)"
}
if ($result.Output.Length -ne $expectedSamples.Length * 4) {
    throw "Expected $($expectedSamples.Length * 4) raw output bytes, got $($result.Output.Length)."
}
for ($index = 0; $index -lt $expectedSamples.Length; $index++) {
    $actual = [BitConverter]::ToSingle($result.Output, $index * 4)
    if ([Math]::Abs($actual - $expectedSamples[$index]) -gt 0.000001) {
        throw "COREO stdout sample $index mismatch: expected $($expectedSamples[$index]), got $actual."
    }
}
Write-Output 'PASS binary stdin to raw four-channel float32 stdout'

$partialFrame = Invoke-CoreoStreamProcess -InputBytes ([byte[]]::new(7))
if ($partialFrame.ExitCode -ne 1 -or $partialFrame.Output.Length -ne 0 -or
    $partialFrame.Error -notmatch 'partial stereo float32 frame') {
    throw 'The stdin/stdout converter must reject a partial input frame without writing audio to stdout.'
}
Write-Output 'PASS rejects incomplete input before writing stdout'
Write-Output 'All COREO stream tests passed.'
