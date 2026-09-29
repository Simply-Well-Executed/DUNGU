# DUNGU

DUNGU is a Windows process-loopback peak meter implemented in PowerShell 7
with its native audio interop embedded as C# and compiled by `Add-Type`.
It activates capture only for the process IDs explicitly selected by the
caller, computes peak levels in memory, and displays local meter bars. It does
not save, transmit, or play captured audio.

Process loopback requires Windows build 20348 or newer. The meter uses the
selected process tree by default; pass `-ExcludeProcessTree` to target only the
specified process. `-DurationSeconds 0` runs until Ctrl+C.

```powershell
Get-Process -Name spotify | Select-Object Id, ProcessName
.\DUNGU.ps1 -ProcessId 1234 -DurationSeconds 20
.\DUNGU.ps1 -ProcessId 1234,5678 -ExcludeProcessTree
.\DUNGU.ps1 -CompileOnly
.\DUNGU.ps1 -SelfTest
.\tests\DUNGU.Tests.ps1
```

The implementation uses the inline process-loopback activation structure,
correct COM interface IDs, and the system mix format. Peak decoding supports
PCM 8/16/24/32-bit and IEEE float 32/64-bit formats, including
`WAVEFORMATEXTENSIBLE`. It rejects unknown layouts rather than treating their
bytes as floats. Capture and COM objects are owned by a dedicated MTA thread;
CPU affinity, sample companding, audio queues, file output, and network output
are intentionally omitted from this meter.

`-SelfTest` validates native layouts and sample decoding without activating an
audio endpoint or capturing audio.
