# DUNGU

DUNGU is a Windows process-loopback peak meter implemented in PowerShell 7
with its native audio interop embedded as C# and compiled by `Add-Type`.
It activates capture only for the process IDs explicitly selected by the
caller, computes peak levels in memory, and displays local meter bars. It does
not save or play captured audio; optional `-EnablePipe` streams packets only
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
worker writes packets; the capture thread only enqueues source bytes into the
bounded `-PipeQueuePackets` queue (default 1; increase it if scheduling jitter
causes drops). The worker tries lossless ZLIB and uses it only when it saves
space; it may also use the `sign(x) * sqrt(abs(x))` companded float32 form when
the inverse error is at most `1e-5` and the compressed result beats the
lossless/raw candidate. Otherwise it sends the original bytes. When the queue
fills, the oldest pending packet is dropped to keep the stream near live
rather than stalling capture. Packets arriving before a client connects are
not retained for later delivery. The pipe ACL permits the current user and
LocalSystem, and the native pipe rejects remote clients. Pipe connections and
streams are disposed when the script exits.

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
message boundary. All integers are little-endian. The payload encoding field
determines how to decode each packet: `0` is raw source-format bytes; `1` is
ZLIB-compressed source-format bytes; `2` is ZLIB-compressed companded float32.
For encoding `2`, the format fields describe the float32 payload and a client
can approximate the original with `sign(x) * x * x` when the companding flag is
set. The per-process sequence may have gaps when packets arrive before a client
connects or the bounded queue drops stale packets.

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
| 50 | 1 | Payload encoding (`0` raw, `1` ZLIB raw, `2` ZLIB companded float32) |
| 51 | 1 | Companding applied (`0` no, `1` yes) |
| 52 | 4 | Frame count |
| 56 | 4 | Payload byte length |
| 60 | 4 | WASAPI capture flags |

`-SelfTest` validates native layouts, ZLIB framing/checksums, bounded companding
error, ring/timeline alignment, repeatable reads, and a local named-pipe
round-trip without activating an audio endpoint or capturing audio.

## One-command quad to float WAV conversion

`tools/Convert-AnythingToCoreoFloat.ps1` is an offline, post-capture converter.
It directly accepts mono or stereo RIFF/WAVE containing PCM 8/16/24/32-bit or
IEEE-float 32/64-bit samples. Other inputs are decoded from their first audio
stream by FFmpeg found on `PATH` or passed through `-FfmpegPath`, then staged as
temporary stereo IEEE-float32 WAV. Multichannel sources are downmixed to stereo
by FFmpeg; exact format support depends on the installed FFmpeg build. RF64 or
very long sources may exceed the classic RIFF size limit. Extensible stereo
WAVs are read directly only with the conventional front-left/front-right mask
(`0x3`) or an unspecified mask (`0`).

The converter first builds and validates a four-channel intermediate. Channel
1 is YIN (left input in reverse frame order), channel 2 is YIN (right input in
reverse frame order), channel 3 is YAN (left input in forward frame order), and
channel 4 is YAN (right input in forward frame order). Mono input is duplicated
into each left/right pair. It then writes a four-channel IEEE-float32 WAVE with
the same sample rate and frame order, preserving channel order and multiplying
each sample by `-1` exactly once. This is polarity inversion; it does not rotate
or spatialize sound by itself. The final channel mask is `0x33` (front left,
front right, back left, back right).

## Binary stdin/stdout stream mode

`-StdinStdout` is a separate, headerless stream interface. It reads interleaved
stereo IEEE-float32 little-endian samples from stdin and writes interleaved
four-channel IEEE-float32 little-endian samples to stdout. It does not read or
write WAVE headers or add custom chunks. Use FFmpeg at the pipe boundaries to
decode any supported audio source and, if desired, wrap the result in an
ordinary WAVE file:

```powershell
ffmpeg -hide_banner -i .\source.flac -map 0:a:0 -vn -ac 2 -ar 48000 `
  -c:a pcm_f32le -f f32le pipe:1 |
  pwsh -NoProfile -File .\tools\Convert-AnythingToCoreoFloat.ps1 `
    -StdinStdout -FramesPerBlock 16384 |
  ffmpeg -hide_banner -f f32le -ar 48000 -ac 4 -channel_layout quad `
    -i pipe:0 -c:a pcm_f32le -f wav .\source-coreo.wav
```

Use PowerShell 7.4 or newer for byte-preserving native-command pipelines.
The converter itself writes directly to the process' binary stdin/stdout
handles; it does not send audio samples through PowerShell's object pipeline.

The output channel order matches the file converter: channel 1 is inverted
left YIN (entire input in reverse frame order), channel 2 inverted right YIN,
channel 3 inverted left YAN (forward), and channel 4 inverted right YAN
(forward). Mono/stereo conversion and source decoding happen in the FFmpeg
input command; for headerless input, put its `-f`, `-ar`, and `-ac` options
before FFmpeg's `-i`.

Exact whole-stream YIN reversal requires knowing the final frame count. The
tool therefore spools decoded stereo float32 samples to a temporary raw scratch
file, validates the complete input, then writes the transformed samples to
stdout. No output is produced until stdin reaches EOF, so this mode is a
finite-stream pipeline, not a zero-buffer live-audio processor. The scratch
file is deleted when processing ends. `-FramesPerBlock` controls working
memory only; changing it does not change the output ordering. The output is
raw audio with no sample-rate header, so the FFmpeg output command must use the
same rate selected by the input command.

Run the stream checks (no FFmpeg required):

```powershell
pwsh -NoProfile -File .\tools\Convert-AnythingToCoreoFloat.ps1 -StreamSelfTest
pwsh -NoProfile -File .\tests\Convert-AnythingToCoreoFloat.Tests.ps1
```

```powershell
pwsh -NoProfile -File .\tools\Convert-AnythingToCoreoFloat.ps1 `
  -SourcePath .\capture.wav `
  -OutputPath .\capture-coreo-float.wav

# Keep a separate validated quad intermediate as well:
pwsh -NoProfile -File .\tools\Convert-AnythingToCoreoFloat.ps1 `
  -SourcePath .\capture.wav `
  -OutputPath .\capture-coreo-float.wav `
  -QuadOutputPath .\capture-quad.wav

# Decode a compressed source via FFmpeg (automatic when ffmpeg is on PATH):
pwsh -NoProfile -File .\tools\Convert-AnythingToCoreoFloat.ps1 `
  -SourcePath .\song.flac `
  -OutputPath .\song-coreo-float.wav `
  -FfmpegPath C:\FFmpeg\bin\ffmpeg.exe
```

By default, the intermediate exists only during conversion and is removed once
the final file passes its RIFF, format, frame-count, channel-mask, and finite
sample checks. The final file contains four float32 samples per frame (16 data
bytes/frame); this is a format conversion, not a compression scheme, and may be
larger than the source. The disk-space saving is that the intermediate quad is
not retained unless `-QuadOutputPath` is supplied. Existing destination files
are never overwritten.

The finalization thread asks Windows for the active processor-group mask, tries
the highest active logical processor in the current group first, and restores
its original affinity and managed priority afterward. This pins a thread; it
does not park a CPU core, reserve a “cryptography core,” or prevent interrupts.
The converter validates a temporary output before publishing it. It operates on
files only and does not route sound into this chat.
