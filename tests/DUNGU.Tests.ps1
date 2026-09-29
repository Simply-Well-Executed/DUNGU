#requires -Version 7.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\DUNGU.psm1') -Force -ErrorAction Stop

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -ne $Expected) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

$balanced = Invoke-DunguBidiAudit -Text ([char]0x2066 + 'a' + [char]0x2067 + 'b' + [char]0x200D + [char]0x200C + [char]0x2069 + 'c' + [char]0x2069)
Assert-True $balanced.Balanced 'Nested isolates should balance; ZWJ/ZWNJ should not change depth.'
Assert-Equal $balanced.OpenCount 2 'Open count mismatch.'
Assert-Equal $balanced.CloseCount 2 'Close count mismatch.'
Assert-Equal $balanced.MaximumDepth 2 'Maximum depth mismatch.'
Assert-Equal $balanced.Issues.Count 0 'Balanced input should have no issues.'

$unmatched = Invoke-DunguBidiAudit -Text ([char]0x2069 + 'x' + [char]0x2066)
Assert-True (-not $unmatched.Balanced) 'Unmatched PDI and unclosed isolate should be invalid.'
Assert-Equal $unmatched.Issues.Count 2 'Expected unmatched PDI and unclosed isolate.'
Assert-Equal $unmatched.Issues[0].Code 'unmatched-pdi' 'First issue should be unmatched PDI.'
Assert-Equal $unmatched.Issues[0].CodePointOffset 0 'Unmatched PDI offset mismatch.'
Assert-Equal $unmatched.Issues[1].Code 'unclosed-isolate' 'Second issue should be unclosed isolate.'
Assert-Equal $unmatched.Issues[1].CodePointOffset 2 'Unclosed isolate offset mismatch.'

$crossLine = Invoke-DunguBidiAudit -Text ([char]0x2066 + 'a' + "`r`n" + 'b' + [char]0x2069)
Assert-Equal $crossLine.Issues.Count 2 'Expected cross-line and unmatched PDI issues.'
Assert-Equal $crossLine.Issues[0].Code 'isolate-crosses-line' 'Cross-line isolate issue missing.'
Assert-Equal $crossLine.Issues[0].Line 1 'Cross-line issue should reference the opening line.'
Assert-Equal $crossLine.Issues[1].Code 'unmatched-pdi' 'PDI after the line break should be unmatched.'
Assert-Equal $crossLine.Issues[1].CodePointOffset 5 'PDI code point offset mismatch.'
Assert-Equal $crossLine.Issues[1].ByteOffset 7 'PDI UTF-8 byte offset mismatch.'
Assert-Equal $crossLine.Issues[1].Line 2 'PDI line number mismatch.'

$supplementary = Invoke-DunguBidiAudit -Text ([char]::ConvertFromUtf32(0x1F600) + [char]0x2069)
Assert-Equal $supplementary.Issues[0].CodePointOffset 1 'Supplementary character code point offset mismatch.'
Assert-Equal $supplementary.Issues[0].ByteOffset 4 'Supplementary character UTF-8 offset mismatch.'

foreach ($separator in @([char]0x0085, [char]0x2028, [char]0x2029)) {
    $lineReport = Invoke-DunguBidiAudit -Text ([char]0x2068 + 'a' + $separator + 'b')
    Assert-Equal $lineReport.Issues.Count 1 "Expected one isolate issue for separator U+$('{0:X4}' -f [int]$separator)."
    Assert-Equal $lineReport.Issues[0].Code 'isolate-crosses-line' 'Unicode line separator was not recognized.'
}

$invalidSurrogate = 'abc' + [char]0xD800
try {
    Invoke-DunguBidiAudit -Text $invalidSurrogate | Out-Null
    throw 'Unpaired surrogate should have raised InvalidUnicodeException.'
}
catch [Dungu.InvalidUnicodeException] {
    Assert-Equal $_.Exception.Utf16Offset 3 'Invalid surrogate offset mismatch.'
}

$empty = Invoke-DunguBidiAudit -Text ''
Assert-True $empty.Balanced 'Empty input should be balanced.'
Assert-Equal $empty.Issues.Count 0 'Empty input should have an empty issue list.'

Write-Output 'All DUNGU tests passed.'
