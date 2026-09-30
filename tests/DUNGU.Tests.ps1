#requires -Version 7.0
$ErrorActionPreference = 'Stop'

$powerShell = (Get-Command pwsh -ErrorAction Stop).Source
$scriptPath = Join-Path $PSScriptRoot '..\DUNGU.ps1'
$output = @(& $powerShell -NoLogo -NoProfile -File $scriptPath -SelfTest 2>&1)
$selfTestExitCode = $LASTEXITCODE
$output | ForEach-Object { Write-Output $_ }
if ($selfTestExitCode -ne 0) {
    throw "DUNGU offline self-tests failed with exit code $selfTestExitCode."
}

$compileOutput = @(& $powerShell -NoLogo -NoProfile -File $scriptPath -CompileOnly 2>&1)
$compileExitCode = $LASTEXITCODE
$compileOutput | ForEach-Object { Write-Output $_ }
if ($compileExitCode -ne 0) {
    throw "DUNGU C# compilation check failed with exit code $compileExitCode."
}

$usageOutput = @(& $powerShell -NoLogo -NoProfile -File $scriptPath 2>&1)
$usageExitCode = $LASTEXITCODE
if ($usageExitCode -ne 2 -or ($usageOutput -join "`n") -notmatch 'specify one or more target process IDs') {
    throw "DUNGU should reject a missing target PID with exit code 2; got $usageExitCode."
}

Write-Output 'All DUNGU PowerShell tests passed. No audio capture was started.'
