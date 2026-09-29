#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [AllowEmptyString()]
    [string]$Text,

    [Parameter(ValueFromPipeline = $true)]
    [AllowEmptyString()]
    [string]$InputText,

    [switch]$Json
)

begin {
    Import-Module (Join-Path $PSScriptRoot 'DUNGU.psm1') -ErrorAction Stop
    $textParts = [System.Collections.Generic.List[string]]::new()
    $textWasProvided = $PSBoundParameters.ContainsKey('Text')
    if ($textWasProvided) {
        $textParts.Add($Text)
    }
}

process {
    if ($PSBoundParameters.ContainsKey('InputText')) {
        if ($textWasProvided) {
            [Console]::Error.WriteLine('error: provide text either as an argument or through the pipeline, not both')
            exit 2
        }
        $textWasProvided = $true
        $textParts.Add($InputText)
    }
}

end {
    if ($textWasProvided) {
        $Text = [string]::Join([Environment]::NewLine, $textParts)
    }
    else {
        try {
            $Text = [Console]::In.ReadToEnd()
        }
        catch [System.IO.IOException] {
            [Console]::Error.WriteLine("error: reading standard input: $($_.Exception.Message)")
            exit 2
        }
    }

    try {
        $report = Invoke-DunguBidiAudit -Text $Text
    }
    catch [Dungu.InvalidUnicodeException] {
        [Console]::Error.WriteLine("error: $($_.Exception.Message)")
        exit 2
    }

    if ($Json) {
        $report | ConvertTo-Json -Depth 4
    }
    else {
        "Balanced: $($report.Balanced)"
        "Isolates opened: $($report.OpenCount)"
        "PDIs encountered: $($report.CloseCount)"
        "Maximum nesting depth: $($report.MaximumDepth)"
        foreach ($issue in $report.Issues) {
            "Issue: $($issue.Code) at line $($issue.Line), code point $($issue.CodePointOffset), byte $($issue.ByteOffset) ($($issue.Control)): $($issue.Message)"
        }
    }

    if (-not $report.Balanced) {
        exit 1
    }
    exit 0
}
