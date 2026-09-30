# DUNGU v1 packet header and WAVE output note

## Scope

This note describes the 64-byte DUNGU v1 packet header used by
`DUNGU.ps1`, and the WAVE chunks written by
`Receive-DunguPipeWave.ps1`. The DUNGU header is transport metadata. A RIFF
`LIST` chunk is file metadata; it is not part of a DUNGU packet.

The named pipe is a **byte stream**, not a message queue. A receiver reads one
complete 64-byte header, then exactly the payload byte count declared in that
header, and repeats. A pipe write boundary does not indicate a packet boundary.
All multibyte integers in the header are little-endian.

## Header layout

Every v1 packet has the same fixed header length. No field below is omitted or
optional on the wire.

| Offset | Size | Field | Meaning |
| ---: | ---: | --- | --- |
| 0 | 4 bytes | Magic | ASCII `DNGU` |
| 4 | 2 bytes | Version | `1` for this protocol |
| 6 | 2 bytes | Header length | `64` bytes |
| 8 | 8 bytes | Sequence | Per-process packet sequence number |
| 16 | 8 bytes | QPC position | WASAPI performance-counter position |
| 24 | 8 bytes | Device position | WASAPI audio-device frame position |
| 32 | 4 bytes | Process ID | Source process ID |
| 36 | 4 bytes | Sample rate | Samples per second |
| 40 | 2 bytes | Channels | Interleaved channel count |
| 42 | 2 bytes | Format tag | `1` = PCM; `3` = IEEE float |
| 44 | 2 bytes | Container bits | Bits stored for each sample |
| 46 | 2 bytes | Valid bits | Significant bits in the sample container |
| 48 | 2 bytes | Block alignment | Bytes per interleaved sample frame |
| 50 | 1 byte | Storage mode | `0` raw; `1` zlib-compressed raw; `2` zlib-compressed companded float32 |
| 51 | 1 byte | Companding flag | `0` not companded; `1` companding applied |
| 52 | 4 bytes | Frame count | Audio sample frames in this packet, per channel |
| 56 | 4 bytes | Payload length | Number of encoded payload bytes immediately after the header |
| 60 | 4 bytes | Capture flags | WASAPI capture-buffer flags |

The byte counts total 64. There is no spare or optional header region in v1.
An implementation that does not recognize the version or header length must
not guess at a layout; it should reject the packet or use a separately defined
future protocol version.

## Required values and cross-field rules

All fields are physically required, even when a consumer does not use their
meaning. The decoder also checks the fields needed to safely interpret the
payload:

- The magic, version, and header length must identify DNGU v1.
- The process ID must identify the source named pipe.
- Sample rate, channel count, frame count, and block alignment must be valid.
- Format tag, container bits, and valid bits must agree. PCM supports 8-, 16-,
  24-, or 32-bit containers; IEEE float supports 32- or 64-bit samples.
- The declared payload length must fit the actual packet. For raw mode it must
  equal `frame count × block alignment`; compressed modes must expand to that
  same decoded length.
- Mode `0` carries original-format bytes and requires the companding flag to be
  zero.
- Mode `1` carries zlib-compressed original-format bytes and requires the
  companding flag to be zero.
- Mode `2` carries zlib-compressed IEEE float32 samples. Its format fields must
  describe float32, and its companding flag must be one. The DUNGU implementation
  expands a sample approximately as `sign(x) × x × x` when decoding this mode.
- The sequence field is always present. Sequence gaps are allowed: packets may
  have been dropped or missed before a receiver connected. A gap is evidence of
  discontinuity, not a reason to infer the missing audio.

The QPC position, device position, and capture-flags fields remain required
header values. A simple file converter may not need the positions for decoding;
that does not make their bytes optional. Capture flags are retained in the
packet metadata; the DUNGU code specifically recognizes WASAPI's silent-buffer
bit (`0x00000002`).

## What is optional

There are **no optional fields in the DUNGU v1 header**. Optionality applies at
other layers:

1. A downstream consumer may choose not to use sequence/QPC/device-position
   metadata for a simple sequential audio file. The sender still includes it.
2. The named-pipe receiver can choose which capture metadata to write into the
   output file. It currently writes an INFO `LIST` chunk with `INAM`, `ISFT`,
   and `ICMT` strings.
3. RIFF/WAVE metadata such as `LIST/INFO` is separate from audio payload and is
   optional to general WAVE playback. The DUNGU receiver emits it for context;
   it is not sent through the pipe.

## WAVE file emitted by the receiver

`Receive-DunguPipeWave.ps1` normalizes packets to interleaved IEEE float32,
keeping the first packet's sample rate and channel count. It writes these RIFF
chunks in order:

| Chunk | Status in receiver output | Purpose |
| --- | --- | --- |
| `fmt ` | Required | Describes IEEE float32, channels, sample rate, and block alignment |
| `fact` | Written | Records the number of sample frames for the non-PCM float format |
| `LIST` / `INFO` | Optional WAVE metadata; emitted here | Contains title, software, and capture notes |
| `data` | Required | Interleaved float32 audio bytes |

The receiver patches RIFF size, `fact` frame count, and data size after capture.
It refuses to overwrite an existing destination and stops at classic RIFF's
4 GiB size limit. It does not insert silence for sequence gaps; it reports
observed discontinuities instead.

## Provenance

The packet layout and payload-mode rules above match `AudioPipeProtocol` and
the protocol table in the repository's `README.md`. The output chunk ordering
and metadata describe the companion receiver script in this folder. This note
documents the implementation; it does not claim a packet was captured or that
audio was listened to.

References: [repository README](../README.md), [DUNGU implementation](../DUNGU.ps1),
[Microsoft RIFF services](https://learn.microsoft.com/en-us/windows/win32/multimedia/resource-interchange-file-format-services),
and [Microsoft RIFF overview](https://learn.microsoft.com/en-us/windows/win32/xaudio2/resource-interchange-file-format--riff-).

## Optional COREO YIN/YAN derived quad file

`Convert-StereoWavToYinYanQuad.ps1` is an optional post-capture transform. It
does not change DUNGU v1 packets or the named-pipe receiver. It accepts a
stereo, 16-bit PCM WAVE file and writes a four-channel PCM WAVEFORMATEXTENSIBLE
file:

| Output channel | Speaker label | Content |
| ---: | --- | --- |
| 1 | Front Left | Source left channel in reverse frame order (YIN) |
| 2 | Front Right | Source right channel in reverse frame order (YIN) |
| 3 | Back Left | Source left channel in original frame order (YAN) |
| 4 | Back Right | Source right channel in original frame order (YAN) |

The source is not modified. These four tracks are derived from the same two
source channels; they do not represent four separately captured inputs. The
converter labels this in a `LIST/INFO` comment. Its extensible format uses
channel mask `0x33` (front left, front right, back left, back right). The
standard channel mask identifies speaker positions and their channel order;
it does not assert anything about the provenance or independence of the audio.

References: [Microsoft WAVEFORMATEXTENSIBLE](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ksmedia/ns-ksmedia-waveformatextensible)
and [Microsoft channel-mask guidance](https://learn.microsoft.com/en-us/windows-hardware/drivers/audio/channel-mask).

## One-command validated quad to float32 conversion

`Convert-AnythingToCoreoFloat.ps1` combines source decoding, quad construction,
validation, and final IEEE-float32 writing. It directly accepts mono/stereo
classic RIFF/WAVE with uncompressed PCM 8/16/24/32-bit or IEEE-float 32/64-bit
samples. Other inputs are decoded from their first audio stream by FFmpeg from
`PATH` or `-FfmpegPath`, then staged as temporary stereo IEEE-float32 WAVE.
Multichannel sources are downmixed to stereo by FFmpeg; exact codec support
depends on the installed FFmpeg build. RF64 or very long sources may exceed
classic RIFF's size limit. Extensible stereo WAVE is read directly only with
the conventional front-left/front-right channel mask (`0x3`) or an unspecified
mask (`0`). The source remains untouched and existing destinations are never
overwritten.

The intermediate channel map follows the established quad transform:

| Quad channel | Content |
| ---: | --- |
| 1 | YIN: source left in reverse frame order; mono is duplicated |
| 2 | YIN: source right in reverse frame order; mono is duplicated |
| 3 | YAN: source left in forward frame order; mono is duplicated |
| 4 | YAN: source right in forward frame order; mono is duplicated |

The script reopens that intermediate and validates RIFF boundaries, format,
channel mask, sample rate, frame count, and representable finite sample values.
Only after that check does it write a four-channel IEEE-float32 file. Final
channels and frame order are preserved, and every sample is multiplied by `-1`
once. This operation reverses sample polarity. It is not a geometric rotation,
spatial renderer, or proof of four-dimensional acoustic output. The resulting
file is four-channel audio data with speaker mask `0x33`.

The final file contains 16 audio-data bytes per frame. It is not compressed and
may take more space than the source. Omitting `-QuadOutputPath` makes the quad
intermediate temporary and removes it after successful validation, avoiding a
second retained copy. Passing `-QuadOutputPath` retains that validated
intermediate for inspection or reuse. The final output is also written to a
temporary path, reopened and validated, then moved into place.

The finalization worker queries Windows' active processor-group mask and tries
the highest active logical processor in its current group first. If Windows
rejects that affinity, it tries the next lower active processor. It raises the
managed thread priority to `Highest` for the conversion and restores the
previous priority and affinity afterward. Processor affinity binds the thread;
it does not park a CPU, identify a dedicated cryptography core, or suppress
system interrupts. Run it in 64-bit PowerShell because the active affinity mask
is pointer-sized.

The affinity query uses `GetLogicalProcessorInformationEx(RelationGroup)` to
read each group's active mask; the pin and restore use `SetThreadGroupAffinity`.
These APIs report and set processor affinity, not whether a core is idle or can
be power-parked. See Microsoft's [processor-group query](https://learn.microsoft.com/en-us/windows/desktop/api/sysinfoapi/nf-sysinfoapi-getlogicalprocessorinformationex),
[group layout](https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-group_relationship),
and [thread-affinity API](https://learn.microsoft.com/en-us/windows/win32/api/processtopologyapi/nf-processtopologyapi-setthreadgroupaffinity).

The script is a local file-conversion tool. It does not connect to the DUNGU
named pipe, create a Windows audio device, or supply audio to this chat. See the
[repository workflow and examples](../README.md#one-command-quad-to-float-wav-conversion).
