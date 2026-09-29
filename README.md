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
.\DUNGU.ps1 -ProcessId 1234 -DurationSeconds 20 -ReplayPasses 3
.\DUNGU.ps1 -ProcessId 1234,5678 -ExcludeProcessTree
.\DUNGU.ps1 -CompileOnly
.\DUNGU.ps1 -SelfTest
.\tests\DUNGU.Tests.ps1
```

All selected processes share a 256 MiB in-memory payload ring and a
1,048,576-entry timeline ring (about 68 MiB of metadata). Each timeline entry
records process ID, QPC/device positions, source format, and the exact payload
offset/length. Audio and timeline entries are evicted together, and readers can
re-read retained sequences without consuming or mutating them.

Each capture packet is independently encoded. DUNGU tries ZLIB on the original
mix-format bytes and stores raw bytes instead when compression would expand the
packet. It may also try the reference's SIMD `sign(x) * sqrt(abs(x))` companding
with packet-level mean-amplitude hysteresis at 0.65/0.195. This makes each
packet independently decodable rather than carrying a per-vector state map.
That candidate is retained only when its measured inverse error is at most
`1e-5` and its ZLIB payload is smaller than the lossless/raw candidate.
Otherwise the original samples are retained. Compression savings depend on the
signal; they are measured, not assumed.

`-ReplayPasses N` re-runs the current signal processor over the retained
timeline after capture stops. Each pass reads the same data non-destructively.
This provides repeatable input for later processor improvements; it does not
train or update a model. The ring is volatile process memory and disappears
when DUNGU exits.

The implementation uses the inline process-loopback activation structure,
correct COM interface IDs, and the system mix format. Decoding supports PCM
8/16/24/32-bit and IEEE float 32/64-bit formats, including
`WAVEFORMATEXTENSIBLE`, and rejects unknown layouts. Capture and COM objects
are owned by a dedicated MTA thread. No audio file or network output is
implemented.

`-SelfTest` validates native layouts, ZLIB framing/checksums, bounded companding
error, ring/timeline alignment, and repeatable reads without activating an
audio endpoint or capturing audio.
