[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 2147483647)]
    [int] $TargetPid,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $OutputPath,

    [ValidateRange(1, 3600)]
    [int] $DurationSeconds = 60,

    [ValidateRange(1, 300)]
    [int] $ConnectTimeoutSeconds = 15,

    [ValidateRange(1024, 268435456)]
    [int] $MaxPacketBytes = 16777216,

    [ValidateNotNullOrEmpty()]
    [string] $Title = 'DUNGU named-pipe capture'
)

# This receiver is a companion to tools/Recompute-RiffHeader.ps1. It uses the
# DUNGU v1 local byte-stream protocol and writes float32 WAVE with LIST/INFO
# metadata. It does not install a driver, attach to another process, or start
# audio capture; the DUNGU producer must already be running for TargetPid.

$csharpCode = @'
using System;
using System.Buffers.Binary;
using System.IO;
using System.IO.Compression;
using System.IO.Pipes;
using System.Text;
using System.Threading;

public sealed class DunguPipeWaveResult
{
    public string OutputPath { get; set; }
    public int TargetProcessId { get; set; }
    public int SampleRate { get; set; }
    public int Channels { get; set; }
    public long PacketCount { get; set; }
    public long FrameCount { get; set; }
    public long DataBytes { get; set; }
    public long SequenceGaps { get; set; }
}

public static class DunguPipeWaveReceiver
{
    private const int HeaderSize = 64;
    private const ushort ProtocolVersion = 1;
    private const ushort WaveFormatPcm = 1;
    private const ushort WaveFormatIeeeFloat = 3;
    private const byte StorageRaw = 0;
    private const byte StorageZlibRaw = 1;
    private const byte StorageZlibCompandedFloat32 = 2;
    private const int AudioClientBufferFlagSilent = 2;

    private sealed class Packet
    {
        internal long Sequence;
        internal int ProcessId;
        internal int SampleRate;
        internal int Channels;
        internal ushort FormatTag;
        internal int BitsPerSample;
        internal int ValidBitsPerSample;
        internal int BlockAlign;
        internal byte StorageMode;
        internal byte CompandingApplied;
        internal int FrameCount;
        internal int PayloadLength;
        internal int Flags;
        internal int DecodedLength;
    }

    private sealed class WaveWriter : IDisposable
    {
        private readonly FileStream _stream;
        private readonly BinaryWriter _writer;
        private readonly ushort _channels;
        private readonly uint _sampleRate;
        private readonly ushort _blockAlign;
        private readonly long _factSampleCountOffset;
        private readonly long _dataSizeOffset;
        private bool _completed;

        internal string Path { get; private set; }
        internal long DataBytes { get; private set; }

        internal WaveWriter(string path, int channels, int sampleRate, string title, int targetPid)
        {
            if (channels <= 0 || channels > ushort.MaxValue)
                throw new InvalidDataException("The channel count cannot be represented in WAVE.");
            if (sampleRate <= 0)
                throw new InvalidDataException("The sample rate is invalid.");

            Path = System.IO.Path.GetFullPath(path);
            string directory = System.IO.Path.GetDirectoryName(Path);
            if (String.IsNullOrEmpty(directory) || !Directory.Exists(directory))
                throw new DirectoryNotFoundException("The output directory does not exist: " + directory);

            _channels = (ushort)channels;
            _sampleRate = (uint)sampleRate;
            int align = checked(channels * sizeof(float));
            if (align > ushort.MaxValue)
                throw new InvalidDataException("The float32 WAVE block alignment is too large.");
            _blockAlign = (ushort)align;

            _stream = new FileStream(Path, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.Read,
                65536, FileOptions.SequentialScan);
            _writer = new BinaryWriter(_stream, Encoding.ASCII, true);

            try
            {
                WriteFourCc(_writer, "RIFF");
                _writer.Write((uint)0); // Patched after capture.
                WriteFourCc(_writer, "WAVE");

                WriteFourCc(_writer, "fmt ");
                _writer.Write((uint)16);
                _writer.Write(WaveFormatIeeeFloat);
                _writer.Write(_channels);
                _writer.Write(_sampleRate);
                _writer.Write(checked(_sampleRate * _blockAlign));
                _writer.Write(_blockAlign);
                _writer.Write((ushort)32);

                // Record the sample-frame count in a fact chunk for this float WAVE file.
                WriteFourCc(_writer, "fact");
                _writer.Write((uint)4);
                _factSampleCountOffset = _stream.Position;
                _writer.Write((uint)0); // Patched after capture.

                byte[] listPayload = CreateInfoList(title, targetPid);
                WriteFourCc(_writer, "LIST");
                _writer.Write((uint)listPayload.Length);
                _writer.Write(listPayload);
                if ((listPayload.Length & 1) != 0)
                    _writer.Write((byte)0);

                WriteFourCc(_writer, "data");
                _dataSizeOffset = _stream.Position;
                _writer.Write((uint)0); // Patched after capture.
                _writer.Flush();
            }
            catch
            {
                _writer.Dispose();
                _stream.Dispose();
                try { File.Delete(Path); } catch { }
                throw;
            }
        }

        internal void Append(float[] samples, int frames)
        {
            int sampleCount = checked(frames * _channels);
            if (frames <= 0 || samples == null || samples.Length != sampleCount)
                throw new InvalidDataException("A decoded packet has an inconsistent frame count.");

            int byteCount = checked(sampleCount * sizeof(float));
            long resultingRiffSize = checked(_stream.Length - 8L + byteCount);
            if (resultingRiffSize > UInt32.MaxValue)
                throw new InvalidDataException("The capture exceeds classic RIFF's 4 GiB size limit.");

            byte[] bytes = new byte[byteCount];
            Buffer.BlockCopy(samples, 0, bytes, 0, byteCount);
            _writer.Write(bytes);
            DataBytes = checked(DataBytes + byteCount);
        }

        internal void Complete()
        {
            if (_completed)
                return;
            if (DataBytes == 0 || DataBytes % _blockAlign != 0)
                throw new InvalidDataException("No complete float32 sample frames were captured.");

            long riffSize = checked(_stream.Length - 8L);
            if (riffSize > UInt32.MaxValue || DataBytes > UInt32.MaxValue)
                throw new InvalidDataException("The capture exceeds classic RIFF's size limits.");

            uint frames = checked((uint)(DataBytes / _blockAlign));
            _writer.Flush();
            _stream.Position = 4;
            _writer.Write((uint)riffSize);
            _stream.Position = _factSampleCountOffset;
            _writer.Write(frames);
            _stream.Position = _dataSizeOffset;
            _writer.Write((uint)DataBytes);
            _writer.Flush();
            _stream.Flush(true);
            _completed = true;
        }

        public void Dispose()
        {
            _writer.Dispose();
            _stream.Dispose();
        }

        private static byte[] CreateInfoList(string title, int targetPid)
        {
            using (MemoryStream memory = new MemoryStream())
            using (BinaryWriter writer = new BinaryWriter(memory, Encoding.ASCII, true))
            {
                WriteFourCc(writer, "INFO");
                WriteInfoString(writer, "INAM", CleanInfoText(title));
                WriteInfoString(writer, "ISFT", "DUNGU Pipe Receiver");
                WriteInfoString(writer, "ICMT",
                    "Local DunguAudioPipe capture for PID " + targetPid
                    + "; normalized to IEEE float32; sequence gaps, if any, are not filled with silence.");
                writer.Flush();
                return memory.ToArray();
            }
        }

        private static string CleanInfoText(string value)
        {
            return (value ?? String.Empty).Replace("\0", String.Empty);
        }

        private static void WriteInfoString(BinaryWriter writer, string id, string value)
        {
            byte[] bytes = Encoding.ASCII.GetBytes(value + "\0");
            WriteFourCc(writer, id);
            writer.Write((uint)bytes.Length);
            writer.Write(bytes);
            if ((bytes.Length & 1) != 0)
                writer.Write((byte)0);
        }
    }

    public static DunguPipeWaveResult Capture(
        int targetPid,
        string outputPath,
        int durationSeconds,
        int connectTimeoutSeconds,
        int maxPacketBytes,
        string title)
    {
        if (targetPid <= 0)
            throw new ArgumentOutOfRangeException("targetPid");
        if (String.IsNullOrWhiteSpace(outputPath))
            throw new ArgumentException("An output path is required.", "outputPath");
        if (durationSeconds <= 0 || connectTimeoutSeconds <= 0 || maxPacketBytes <= 0)
            throw new ArgumentOutOfRangeException("Capture limits must be positive.");
        if (!BitConverter.IsLittleEndian)
            throw new PlatformNotSupportedException("The DUNGU v1 receiver currently requires a little-endian host.");

        string fullOutputPath = System.IO.Path.GetFullPath(outputPath);
        if (File.Exists(fullOutputPath))
            throw new IOException("Refusing to overwrite an existing output file: " + fullOutputPath);

        string pipeName = "DunguAudioPipe_" + targetPid;
        WaveWriter wave = null;
        long packetCount = 0;
        long totalFrames = 0;
        long sequenceGaps = 0;
        long lastSequence = Int64.MinValue;
        int captureSampleRate = 0;
        int captureChannels = 0;

        try
        {
            using (NamedPipeClientStream pipe = new NamedPipeClientStream(
                ".", pipeName, PipeDirection.In, PipeOptions.Asynchronous))
            {
                pipe.Connect(checked(connectTimeoutSeconds * 1000));

                using (CancellationTokenSource timeout = new CancellationTokenSource())
                {
                    timeout.CancelAfter(TimeSpan.FromSeconds(durationSeconds));
                    using (timeout.Token.Register(delegate
                    {
                        try { pipe.Dispose(); } catch { }
                    }))
                    {
                        try
                        {
                            while (true)
                            {
                                byte[] header = new byte[HeaderSize];
                                if (!ReadExactly(pipe, header, true, timeout.Token))
                                    break;

                                Packet packet = ParseHeader(header, targetPid, maxPacketBytes);
                                byte[] payload = new byte[packet.PayloadLength];
                                if (!ReadExactly(pipe, payload, false, timeout.Token))
                                    throw new EndOfStreamException("A DUNGU payload ended before its declared length.");

                                byte[] decoded = DecodePayload(packet, payload);
                                float[] samples = DecodeSamples(packet, decoded);

                                if (captureSampleRate == 0)
                                {
                                    captureSampleRate = packet.SampleRate;
                                    captureChannels = packet.Channels;
                                    wave = new WaveWriter(fullOutputPath, captureChannels,
                                        captureSampleRate, title, targetPid);
                                }
                                else if (packet.SampleRate != captureSampleRate
                                    || packet.Channels != captureChannels)
                                {
                                    throw new InvalidDataException(
                                        "The pipe changed sample rate or channel count mid-capture; refusing to mix formats in one WAVE file.");
                                }

                                wave.Append(samples, packet.FrameCount);
                                packetCount = checked(packetCount + 1);
                                totalFrames = checked(totalFrames + packet.FrameCount);
                                if (lastSequence != Int64.MinValue
                                    && (lastSequence == Int64.MaxValue || packet.Sequence != lastSequence + 1))
                                    sequenceGaps = checked(sequenceGaps + 1);
                                lastSequence = packet.Sequence;
                            }
                        }
                        catch (OperationCanceledException) when (timeout.IsCancellationRequested)
                        {
                            // Duration limit reached. Finish at the last complete packet.
                        }
                        catch (IOException) when (timeout.IsCancellationRequested)
                        {
                            // Closing the pipe cancels a pending read at the duration limit.
                        }
                        catch (ObjectDisposedException) when (timeout.IsCancellationRequested)
                        {
                            // Closing the pipe cancels a pending read at the duration limit.
                        }
                    }
                }
            }

            if (wave == null || packetCount == 0)
                throw new InvalidOperationException(
                    "The pipe connected, but no complete audio packet arrived during the capture window.");

            wave.Complete();
            return new DunguPipeWaveResult
            {
                OutputPath = fullOutputPath,
                TargetProcessId = targetPid,
                SampleRate = captureSampleRate,
                Channels = captureChannels,
                PacketCount = packetCount,
                FrameCount = totalFrames,
                DataBytes = wave.DataBytes,
                SequenceGaps = sequenceGaps
            };
        }
        finally
        {
            if (wave != null)
            {
                string createdPath = wave.Path;
                long writtenBytes = wave.DataBytes;
                try { wave.Complete(); }
                catch { /* Preserve any primary capture error; a failed finalization remains visible in output handling. */ }
                wave.Dispose();

                if (writtenBytes == 0)
                {
                    try { File.Delete(createdPath); } catch { }
                }
            }
        }
    }

    private static Packet ParseHeader(byte[] header, int targetPid, int maxPacketBytes)
    {
        if (header == null || header.Length != HeaderSize)
            throw new InvalidDataException("A DUNGU header must be exactly 64 bytes.");
        if (header[0] != (byte)'D' || header[1] != (byte)'N'
            || header[2] != (byte)'G' || header[3] != (byte)'U')
            throw new InvalidDataException("The named pipe did not begin with DNGU magic.");
        if (BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(4, 2)) != ProtocolVersion
            || BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(6, 2)) != HeaderSize)
            throw new InvalidDataException("The DUNGU protocol version or header length is unsupported.");

        uint processId = BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(32, 4));
        uint sampleRate = BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(36, 4));
        ushort channels = BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(40, 2));
        ushort formatTag = BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(42, 2));
        ushort bitsPerSample = BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(44, 2));
        ushort validBits = BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(46, 2));
        ushort blockAlign = BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(48, 2));
        byte storageMode = header[50];
        byte compandingApplied = header[51];
        int frameCount = BinaryPrimitives.ReadInt32LittleEndian(header.AsSpan(52, 4));
        int payloadLength = BinaryPrimitives.ReadInt32LittleEndian(header.AsSpan(56, 4));
        int flags = BinaryPrimitives.ReadInt32LittleEndian(header.AsSpan(60, 4));

        if (processId != (uint)targetPid)
            throw new InvalidDataException("The packet PID does not match the requested DUNGU pipe PID.");
        if (sampleRate == 0 || sampleRate > 768000 || channels == 0 || channels > 64)
            throw new InvalidDataException("The packet sample rate or channel count is outside supported limits.");
        if (frameCount <= 0 || payloadLength <= 0 || payloadLength > maxPacketBytes)
            throw new InvalidDataException("The packet frame count or payload length is invalid or exceeds the configured limit.");

        int bytesPerSample;
        if (formatTag == WaveFormatPcm)
        {
            if (bitsPerSample != 8 && bitsPerSample != 16
                && bitsPerSample != 24 && bitsPerSample != 32)
                throw new InvalidDataException("PCM packets must use 8-, 16-, 24-, or 32-bit containers.");
            if (validBits == 0 || validBits > bitsPerSample
                || (bitsPerSample == 8 && validBits != 8))
                throw new InvalidDataException("The PCM valid-bits field is invalid.");
            bytesPerSample = bitsPerSample / 8;
        }
        else if (formatTag == WaveFormatIeeeFloat)
        {
            if ((bitsPerSample != 32 && bitsPerSample != 64) || validBits != bitsPerSample)
                throw new InvalidDataException("IEEE-float packets must use 32- or 64-bit samples with matching valid bits.");
            bytesPerSample = bitsPerSample / 8;
        }
        else
        {
            throw new InvalidDataException("The packet format tag is neither PCM nor IEEE float.");
        }

        if (blockAlign < channels * bytesPerSample)
            throw new InvalidDataException("The packet block alignment is smaller than its sample data.");

        long decodedLengthLong = checked((long)frameCount * blockAlign);
        if (decodedLengthLong <= 0 || decodedLengthLong > maxPacketBytes)
            throw new InvalidDataException("The decoded packet exceeds the configured per-packet byte limit.");
        int decodedLength = checked((int)decodedLengthLong);

        if (storageMode == StorageRaw)
        {
            if (payloadLength != decodedLength || compandingApplied != 0)
                throw new InvalidDataException("A raw packet must match the decoded size and cannot be companded.");
        }
        else if (storageMode == StorageZlibRaw)
        {
            if (payloadLength >= decodedLength || compandingApplied != 0)
                throw new InvalidDataException("A zlib-raw packet must be smaller than decoded audio and uncompanded.");
        }
        else if (storageMode == StorageZlibCompandedFloat32)
        {
            if (formatTag != WaveFormatIeeeFloat || bitsPerSample != 32 || validBits != 32
                || blockAlign != channels * sizeof(float)
                || payloadLength >= decodedLength || compandingApplied != 1)
                throw new InvalidDataException("A companded packet must describe compressed float32 samples with the companding flag set.");
        }
        else
        {
            throw new InvalidDataException("The DUNGU payload encoding is unknown.");
        }

        return new Packet
        {
            Sequence = BinaryPrimitives.ReadInt64LittleEndian(header.AsSpan(8, 8)),
            ProcessId = (int)processId,
            SampleRate = (int)sampleRate,
            Channels = channels,
            FormatTag = formatTag,
            BitsPerSample = bitsPerSample,
            ValidBitsPerSample = validBits,
            BlockAlign = blockAlign,
            StorageMode = storageMode,
            CompandingApplied = compandingApplied,
            FrameCount = frameCount,
            PayloadLength = payloadLength,
            Flags = flags,
            DecodedLength = decodedLength
        };
    }

    private static byte[] DecodePayload(Packet packet, byte[] payload)
    {
        if (payload.Length != packet.PayloadLength)
            throw new InvalidDataException("The payload length does not match its DUNGU header.");

        if (packet.StorageMode == StorageRaw)
            return payload;

        return DecompressZlib(payload, packet.DecodedLength);
    }

    private static byte[] DecompressZlib(byte[] input, int expectedLength)
    {
        if (input == null || input.Length < 6)
            throw new InvalidDataException("The zlib payload is truncated.");

        int cmf = input[0];
        int flg = input[1];
        if ((cmf & 0x0F) != 8 || (cmf >> 4) > 7
            || (((cmf << 8) | flg) % 31) != 0 || (flg & 0x20) != 0)
            throw new InvalidDataException("The zlib header is invalid or requests a preset dictionary.");

        uint expectedChecksum = ((uint)input[input.Length - 4] << 24)
            | ((uint)input[input.Length - 3] << 16)
            | ((uint)input[input.Length - 2] << 8)
            | input[input.Length - 1];

        using (MemoryStream deflateInput = new MemoryStream(input, 2, input.Length - 6, false))
        using (DeflateStream inflater = new DeflateStream(deflateInput, CompressionMode.Decompress))
        using (MemoryStream output = new MemoryStream(expectedLength))
        {
            byte[] scratch = new byte[8192];
            int read;
            while ((read = inflater.Read(scratch, 0, scratch.Length)) != 0)
            {
                if (output.Length > expectedLength - read)
                    throw new InvalidDataException("The zlib payload expands beyond its declared DUNGU frame size.");
                output.Write(scratch, 0, read);
            }

            byte[] result = output.ToArray();
            if (result.Length != expectedLength)
                throw new InvalidDataException("The zlib payload does not match its declared DUNGU frame size.");
            if (Adler32(result) != expectedChecksum)
                throw new InvalidDataException("The zlib Adler-32 checksum is incorrect.");
            return result;
        }
    }

    private static uint Adler32(byte[] data)
    {
        const uint Modulus = 65521;
        uint first = 1;
        uint second = 0;
        for (int index = 0; index < data.Length; index++)
        {
            first = (first + data[index]) % Modulus;
            second = (second + first) % Modulus;
        }
        return (second << 16) | first;
    }

    private static float[] DecodeSamples(Packet packet, byte[] bytes)
    {
        int sampleCount = checked(packet.FrameCount * packet.Channels);
        float[] samples = new float[sampleCount];
        int bytesPerSample = packet.BitsPerSample / 8;

        for (int frame = 0; frame < packet.FrameCount; frame++)
        {
            int frameOffset = checked(frame * packet.BlockAlign);
            for (int channel = 0; channel < packet.Channels; channel++)
            {
                int offset = checked(frameOffset + channel * bytesPerSample);
                float value = ReadSample(packet, bytes, offset);
                if (packet.StorageMode == StorageZlibCompandedFloat32)
                    value = (value < 0 ? -1.0f : 1.0f) * value * value;
                samples[frame * packet.Channels + channel] = value;
            }
        }
        return samples;
    }

    private static float ReadSample(Packet packet, byte[] data, int offset)
    {
        if (packet.FormatTag == WaveFormatIeeeFloat)
        {
            return packet.BitsPerSample == 32
                ? BitConverter.ToSingle(data, offset)
                : (float)BitConverter.ToDouble(data, offset);
        }

        if (packet.BitsPerSample == 8)
            return (data[offset] - 128) / 128.0f;

        int raw;
        if (packet.BitsPerSample == 16)
        {
            raw = BitConverter.ToInt16(data, offset);
        }
        else if (packet.BitsPerSample == 24)
        {
            raw = data[offset] | (data[offset + 1] << 8) | (data[offset + 2] << 16);
            if ((raw & 0x00800000) != 0)
                raw |= unchecked((int)0xFF000000);
        }
        else
        {
            raw = BitConverter.ToInt32(data, offset);
        }

        int paddingBits = packet.BitsPerSample - packet.ValidBitsPerSample;
        if (paddingBits > 0)
            raw >>= paddingBits;
        return (float)(raw / Math.Pow(2.0, packet.ValidBitsPerSample - 1));
    }

    private static bool ReadExactly(Stream stream, byte[] buffer, bool allowCleanEof, CancellationToken token)
    {
        int offset = 0;
        while (offset < buffer.Length)
        {
            int read = stream.ReadAsync(buffer, offset, buffer.Length - offset, token)
                .GetAwaiter().GetResult();
            if (read == 0)
            {
                if (offset == 0 && allowCleanEof)
                    return false;
                throw new EndOfStreamException("The DUNGU byte stream ended inside a packet.");
            }
            offset += read;
        }
        return true;
    }

    private static void WriteFourCc(BinaryWriter writer, string value)
    {
        byte[] bytes = Encoding.ASCII.GetBytes(value);
        if (bytes.Length != 4)
            throw new ArgumentException("A RIFF chunk identifier must contain four ASCII bytes.", "value");
        writer.Write(bytes);
    }
}
'@

if ($null -eq ('DunguPipeWaveReceiver' -as [type])) {
    Add-Type -TypeDefinition $csharpCode -ErrorAction Stop
}

$capture = [DunguPipeWaveReceiver]::Capture(
    $TargetPid,
    $OutputPath,
    $DurationSeconds,
    $ConnectTimeoutSeconds,
    $MaxPacketBytes,
    $Title
)

$capture | Format-List
if ($capture.SequenceGaps -gt 0) {
    Write-Warning "$($capture.SequenceGaps) DUNGU sequence discontinuity/discontinuities were observed. Missing packets were not replaced with silence."
}
