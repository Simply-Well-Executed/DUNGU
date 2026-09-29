# DUNGU

DUNGU starts with a PowerShell tool backed by embedded C# for auditing Unicode
bidirectional isolate structure. It treats the supplied atlas as a symbolic
map, not a translator; graph labels and transform rules remain out of scope
until their semantics are specified consistently.

The current audit profile:

- LRI (`U+2066`), RLI (`U+2067`), and FSI (`U+2068`) open isolates.
- PDI (`U+2069`) closes the most recently opened isolate on the same line.
- Isolates may not cross a line boundary. CRLF counts as one boundary; CR, LF,
  NEL (`U+0085`), Line Separator (`U+2028`), and Paragraph Separator
  (`U+2029`) each end a line.
- ZWJ (`U+200D`) and ZWNJ (`U+200C`) do not change isolate depth.
- The audit does not normalize, reorder, or otherwise modify the input. Offsets
  are zero-based Unicode code points and UTF-8 bytes; line numbers are
  one-based.

This is a structural check, not a full Unicode Bidirectional Algorithm
implementation, text renderer, expression parser, or translator.

## Run

```powershell
.\DUNGU.ps1 -Text "⁦text⁩"
.\DUNGU.ps1 -Text "⁦text⁩" -Json
Get-Content -Raw -Encoding utf8 .\input.txt | .\DUNGU.ps1
.\tests\DUNGU.Tests.ps1
```

Text can be passed as `-Text` or through the PowerShell pipeline (use
`Get-Content -Raw` to preserve the file's line breaks). With neither, DUNGU
reads from standard input. It exits with
status `0` for structurally balanced input, `1` when the report contains
structural issues, and `2` for invalid Unicode, I/O, or usage errors. The
embedded C# implementation is compiled by PowerShell at runtime; no external
package is required.
