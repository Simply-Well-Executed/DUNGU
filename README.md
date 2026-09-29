# DUNGU

DUNGU is a Windows process-loopback peak meter implemented in PowerShell 7
with its native audio interop embedded as C# and compiled by `Add-Type`.
It activates capture only for the process IDs explicitly selected by the
caller, computes peak levels in memory, and displays local meter bars. It does
not save or play captured audio; optional `-EnablePipe` sends raw packets only
to a same-user local named-pipe client.

Process loopback requires Windows build 20348 or newer. The meter uses the
selected process tree by default; pass `-ExcludeProcessTree` to target only the
specified process. `-DurationSeconds 0` runs until Ctrl+C.

```powershell
Get-Process -Name spotify | Select-Object Id, ProcessName
pwsh -NoProfile -File .\DUNGU.ps1 -ProcessId 1234 -DurationSeconds 20
pwsh -NoProfile -File .\DUNGU.ps1 -ProcessId 1234 -DurationSeconds 20 -ReplayPasses 3
pwsh -NoProfile -File .\DUNGU.ps1 -ProcessId 1234,5678 -ExcludeProcessTree
pwsh -NoProfile -File .\DUNGU.ps1 -ProcessId 1234 -EnablePipe -PipeQueuePackets 1
pwsh -NoProfile -File .\DUNGU.ps1 -CompileOnly
pwsh -NoProfile -File .\DUNGU.ps1 -SelfTest
pwsh -NoProfile -File .\tests\DUNGU.Tests.ps1
```

Run the command through a child `pwsh -File` process from an existing
PowerShell session. DUNGU uses `exit` to return nonzero command-line statuses;
the child process keeps those exits separate from your current session.

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

The implementation uses the inline process-loopback activation structure and
the correct COM interface IDs. It requests shared-mode, stereo, 44.1 kHz,
16-bit PCM and enables Windows PCM conversion: the process-loopback virtual
client can return `E_NOTIMPL` from `IAudioClient::GetMixFormat`, so live capture
does not rely on that call. Decoding supports PCM 8/16/24/32-bit and IEEE float
32/64-bit formats, including `WAVEFORMATEXTENSIBLE`, and rejects unknown
layouts. Capture and COM objects are owned by a dedicated MTA thread.

`-EnablePipe` starts one local named-pipe server per PID at
`\\.\pipe\DunguAudioPipe_<pid>`. The server accepts one same-user client at a
time. The named pipe only exists while the script is running. Its dedicated
worker writes uncompressed source-format audio packets; the capture thread
only enqueues into the bounded `-PipeQueuePackets` queue (default 1; increase
it if scheduling jitter causes drops). When that queue fills, the oldest
pending packet is dropped to keep the stream near live rather than stalling
capture. Packets arriving before a client connects are not retained for later
delivery. The pipe ACL permits the current user and LocalSystem, and the native
pipe rejects remote clients. Pipe connections and streams are disposed when
the script exits.

The pipe is IPC, **not a Windows audio input device**. It does not dynamically
install or create an endpoint visible to other audio applications. To expose
the stream as an application microphone/input, a separate receiver must read
the frames and render them to an already-installed virtual audio cable's
playback endpoint; its corresponding virtual recording endpoint is what other
applications select. Creating/uninstalling such a device requires a virtual
audio driver and is outside this PowerShell process. A literal zero-buffer
audio path is not available: Windows' shared audio engine and the named-pipe
transport buffer internally even when DUNGU's bounded queue is set to one.

## Named-pipe frame format

The pipe is a byte stream, so clients must read exactly the 64-byte header
before reading that frame's `payloadLength` bytes; a pipe write is not a
message boundary. All integers are little-endian. The payload is original,
uncompanded audio in the capture format.

| Offset | Size | Field |
| --- | ---: | --- |
| 0 | 4 | ASCII magic `DNGU` |
| 4 | 2 | Protocol version (`1`) |
| 6 | 2 | Header length (`64`) |
| 8 | 8 | Per-process sequence number |
| 16 | 8 | WASAPI QPC position |
| 24 | 8 | WASAPI device position |
| 32 | 4 | Source process ID |
| 36 | 4 | Sample rate |
| 40 | 2 | Channel count |
| 42 | 2 | Sample format tag (`1` PCM, `3` IEEE float) |
| 44 | 2 | Container bits per sample |
| 46 | 2 | Valid bits per sample |
| 48 | 2 | Block alignment |
| 50 | 1 | Payload encoding (`0` raw) |
| 51 | 1 | Companding flag (`0` for raw pipe audio) |
| 52 | 4 | Frame count |
| 56 | 4 | Payload byte length |
| 60 | 4 | WASAPI capture flags |

`-SelfTest` validates native layouts, ZLIB framing/checksums, bounded companding
error, ring/timeline alignment, repeatable reads, and a local named-pipe
round-trip without activating an audio endpoint or capturing audio.
