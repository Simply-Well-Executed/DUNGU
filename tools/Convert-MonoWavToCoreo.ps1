[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $SourcePath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $OutputPath,

    [ValidateNotNullOrEmpty()]
    [string] $Title = 'COREO YIN reverse - YAN forward'
)

# Creates a derived stereo file from a mono PCM or IEEE-float WAV:
#   channel 1 (Front Left)  = YIN, mono source in reverse time
#   channel 2 (Front Right) = YAN, mono source in original forward time
# The original file is not changed. Both output channels derive from the same
# mono source; this is a two-channel COREO transform, not a two-channel capture.

$csharpCode = @'
using System;
using System.IO;
using System.Text;

public sealed class MonoCoreoConversionReport
{
    public string SourcePath { get; set; }
    public string OutputPath { get; set; }
    public uint SampleRate { get; set; }
    public long Frames { get; set; }
    public long DataBytes { get; set; }
    public int Channels { get; set; }
    public int BitsPerSample { get; set; }
    public string SampleEncoding { get; set; }
    public string ChannelMap { get; set; }
}

public static class CoreoMonoWavConverter
{
    private const ushort WaveFormatPcm = 1;
    private const ushort WaveFormatIeeeFloat = 3;
    private const ushort WaveFormatExtensible = 0xFFFE;
    private const ushort OutputChannels = 2;
    private const uint StereoSpeakerMask = 0x00000003; // Front Left | Front Right
    private const int FramesPerBlock = 16384;

    private static readonly Guid PcmSubFormat =
        new Guid("00000001-0000-0010-8000-00AA00389B71");
    private static readonly Guid FloatSubFormat =
        new Guid("00000003-0000-0010-8000-00AA00389B71");

    private sealed class SourceWave
    {
        internal long DataOffset;
        internal uint DataLength;
        internal uint SampleRate;
        internal ushort BitsPerSample;
        internal ushort ValidBitsPerSample;
        internal ushort BlockAlign;
        internal Guid SubFormat;
    }

    public static MonoCoreoConversionReport Convert(string sourcePath, string outputPath, string title)
    {
        if (String.IsNullOrWhiteSpace(sourcePath))
            throw new ArgumentException("A source WAV path is required.", "sourcePath");
        if (String.IsNullOrWhiteSpace(outputPath))
            throw new ArgumentException("An output WAV path is required.", "outputPath");
        if (!BitConverter.IsLittleEndian)
            throw new PlatformNotSupportedException("WAVE PCM samples require little-endian byte order.");

        string sourceFullPath = Path.GetFullPath(sourcePath);
        string outputFullPath = Path.GetFullPath(outputPath);
        if (String.Equals(sourceFullPath, outputFullPath, StringComparison.OrdinalIgnoreCase))
            throw new IOException("Source and output paths must be different.");
        if (File.Exists(outputFullPath))
            throw new IOException("Refusing to overwrite an existing output file: " + outputFullPath);

        SourceWave source = InspectMonoWave(sourceFullPath);
        if (source.DataLength % source.BlockAlign != 0)
            throw new InvalidDataException("The source data must contain whole mono sample frames.");

        long frames = source.DataLength / source.BlockAlign;
        ushort outputBlockAlign = checked((ushort)(source.BlockAlign * OutputChannels));
        long outputDataLength = checked(frames * outputBlockAlign);
        if (outputDataLength > UInt32.MaxValue)
            throw new InvalidDataException("The converted audio exceeds the classic RIFF 4 GiB limit.");

        byte[] listPayload = CreateInfoList(title, sourceFullPath, source.SubFormat);
        long listPaddedLength = checked(listPayload.Length + (listPayload.Length & 1));
        long outputFileLength = checked(76L + listPaddedLength + outputDataLength);
        long riffSize = outputFileLength - 8L;
        if (riffSize > UInt32.MaxValue)
            throw new InvalidDataException("The converted file exceeds the classic RIFF 4 GiB limit.");

        bool outputCreated = false;
        try
        {
            using (FileStream input = new FileStream(sourceFullPath, FileMode.Open, FileAccess.Read, FileShare.Read))
            using (FileStream output = new FileStream(outputFullPath, FileMode.CreateNew, FileAccess.Write,
                FileShare.Read, 65536, FileOptions.SequentialScan))
            using (BinaryWriter writer = new BinaryWriter(output, Encoding.ASCII, true))
            {
                outputCreated = true;
                WriteOutputHeader(writer, source, outputBlockAlign, (uint)riffSize,
                    (uint)outputDataLength, listPayload);

                byte[] reverseInput = new byte[FramesPerBlock * source.BlockAlign];
                byte[] forwardInput = new byte[FramesPerBlock * source.BlockAlign];
                byte[] outputBlock = new byte[FramesPerBlock * outputBlockAlign];
                long outputFrame = 0;

                while (outputFrame < frames)
                {
                    int blockFrames = (int)Math.Min(FramesPerBlock, frames - outputFrame);
                    int inputBytes = checked(blockFrames * source.BlockAlign);
                    long reverseStartFrame = frames - outputFrame - blockFrames;

                    input.Position = checked(source.DataOffset + reverseStartFrame * source.BlockAlign);
                    ReadExactly(input, reverseInput, inputBytes);
                    input.Position = checked(source.DataOffset + outputFrame * source.BlockAlign);
                    ReadExactly(input, forwardInput, inputBytes);

                    for (int frame = 0; frame < blockFrames; frame++)
                    {
                        int reverseOffset = (blockFrames - 1 - frame) * source.BlockAlign;
                        int forwardOffset = frame * source.BlockAlign;
                        int outputOffset = frame * outputBlockAlign;

                        // YIN: reversed mono sample goes to output channel 1 (Front Left).
                        Buffer.BlockCopy(reverseInput, reverseOffset, outputBlock,
                            outputOffset, source.BlockAlign);
                        // YAN: original forward mono sample goes to output channel 2 (Front Right).
                        Buffer.BlockCopy(forwardInput, forwardOffset, outputBlock,
                            outputOffset + source.BlockAlign, source.BlockAlign);
                    }

                    writer.Write(outputBlock, 0, checked(blockFrames * outputBlockAlign));
                    outputFrame += blockFrames;
                }

                writer.Flush();
                output.Flush(true);
            }
        }
        catch
        {
            if (outputCreated)
            {
                try { File.Delete(outputFullPath); } catch { }
            }
            throw;
        }

        return new MonoCoreoConversionReport
        {
            SourcePath = sourceFullPath,
            OutputPath = outputFullPath,
            SampleRate = source.SampleRate,
            Frames = frames,
            DataBytes = outputDataLength,
            Channels = OutputChannels,
            BitsPerSample = source.BitsPerSample,
            SampleEncoding = source.SubFormat == PcmSubFormat ? "PCM" : "IEEE float",
            ChannelMap = "1=YIN reverse mono, 2=YAN forward mono"
        };
    }

    private static SourceWave InspectMonoWave(string path)
    {
        using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
        using (BinaryReader reader = new BinaryReader(stream, Encoding.ASCII, true))
        {
            if (stream.Length < 12 || ReadFourCc(reader) != "RIFF")
                throw new InvalidDataException("The source is not a RIFF file.");
            uint riffSize = reader.ReadUInt32();
            if (ReadFourCc(reader) != "WAVE")
                throw new InvalidDataException("The source RIFF form is not WAVE.");
            if (riffSize != stream.Length - 8L)
                throw new InvalidDataException("The source RIFF size does not match its file length.");

            bool sawFormat = false;
            bool sawData = false;
            long dataOffset = 0;
            uint dataLength = 0;
            uint sampleRate = 0;
            uint byteRate = 0;
            ushort formatTag = 0;
            ushort channels = 0;
            ushort blockAlign = 0;
            ushort bitsPerSample = 0;
            ushort validBitsPerSample = 0;
            Guid subFormat = Guid.Empty;
            long position = 12;

            while (position <= stream.Length - 8)
            {
                stream.Position = position;
                string chunkId = ReadFourCc(reader);
                uint chunkSize = reader.ReadUInt32();
                long payloadOffset = stream.Position;
                long nextPosition = checked(payloadOffset + chunkSize + (chunkSize & 1L));
                if (nextPosition > stream.Length)
                    throw new InvalidDataException("A source RIFF chunk extends past end-of-file.");

                if (chunkId == "fmt ")
                {
                    if (sawFormat || chunkSize < 16 || chunkSize > 4096)
                        throw new InvalidDataException("The source fmt chunk is missing, repeated, or invalid.");

                    byte[] format = reader.ReadBytes((int)chunkSize);
                    if (format.Length != (int)chunkSize)
                        throw new EndOfStreamException("The source fmt chunk is incomplete.");

                    formatTag = BitConverter.ToUInt16(format, 0);
                    channels = BitConverter.ToUInt16(format, 2);
                    sampleRate = BitConverter.ToUInt32(format, 4);
                    byteRate = BitConverter.ToUInt32(format, 8);
                    blockAlign = BitConverter.ToUInt16(format, 12);
                    bitsPerSample = BitConverter.ToUInt16(format, 14);
                    validBitsPerSample = bitsPerSample;

                    if (formatTag == WaveFormatPcm)
                        subFormat = PcmSubFormat;
                    else if (formatTag == WaveFormatIeeeFloat)
                        subFormat = FloatSubFormat;
                    else if (formatTag == WaveFormatExtensible)
                    {
                        if (format.Length < 40 || BitConverter.ToUInt16(format, 16) < 22)
                            throw new InvalidDataException("The extensible fmt chunk is too short.");

                        validBitsPerSample = BitConverter.ToUInt16(format, 18);
                        byte[] guidBytes = new byte[16];
                        Buffer.BlockCopy(format, 24, guidBytes, 0, guidBytes.Length);
                        subFormat = new Guid(guidBytes);
                    }
                    else
                        throw new InvalidDataException("Only PCM and IEEE-float WAV sources are supported.");

                    sawFormat = true;
                }
                else if (chunkId == "data")
                {
                    if (sawData)
                        throw new InvalidDataException("The source contains more than one data chunk.");
                    dataOffset = payloadOffset;
                    dataLength = chunkSize;
                    sawData = true;
                }

                position = nextPosition;
            }

            if (!sawFormat || !sawData)
                throw new InvalidDataException("The source WAV needs one fmt chunk and one data chunk.");
            if (stream.Length - dataOffset != dataLength + (dataLength & 1L))
                throw new InvalidDataException("The source data chunk must be final so the audio boundary is certain.");
            if (channels != 1 || sampleRate == 0 || blockAlign == 0
                || (long)byteRate != (long)sampleRate * blockAlign)
                throw new InvalidDataException("The source must be a valid mono WAV with a consistent byte rate.");

            bool isPcm = subFormat == PcmSubFormat;
            bool isFloat = subFormat == FloatSubFormat;
            if (!isPcm && !isFloat)
                throw new InvalidDataException("The extensible WAV subtype must be PCM or IEEE float.");

            bool validPcmWidth = bitsPerSample == 8 || bitsPerSample == 16
                || bitsPerSample == 24 || bitsPerSample == 32;
            bool validFloatWidth = bitsPerSample == 32 || bitsPerSample == 64;
            if ((isPcm && !validPcmWidth) || (isFloat && !validFloatWidth))
                throw new InvalidDataException("Unsupported PCM or IEEE-float container width.");
            if (blockAlign != bitsPerSample / 8 || validBitsPerSample == 0
                || validBitsPerSample > bitsPerSample || (isFloat && validBitsPerSample != bitsPerSample))
                throw new InvalidDataException("The source sample width, valid bits, and block alignment disagree.");

            return new SourceWave
            {
                DataOffset = dataOffset,
                DataLength = dataLength,
                SampleRate = sampleRate,
                BitsPerSample = bitsPerSample,
                ValidBitsPerSample = validBitsPerSample,
                BlockAlign = blockAlign,
                SubFormat = subFormat
            };
        }
    }

    private static void WriteOutputHeader(BinaryWriter writer, SourceWave source,
        ushort outputBlockAlign, uint riffSize, uint dataLength, byte[] listPayload)
    {
        uint outputByteRate = checked(source.SampleRate * outputBlockAlign);

        WriteFourCc(writer, "RIFF");
        writer.Write(riffSize);
        WriteFourCc(writer, "WAVE");

        // WAVEFORMATEXTENSIBLE records the two COREO output channels and their speaker positions.
        WriteFourCc(writer, "fmt ");
        writer.Write((uint)40);
        writer.Write(WaveFormatExtensible);
        writer.Write(OutputChannels);
        writer.Write(source.SampleRate);
        writer.Write(outputByteRate);
        writer.Write(outputBlockAlign);
        writer.Write(source.BitsPerSample);
        writer.Write((ushort)22); // cbSize
        writer.Write(source.ValidBitsPerSample);
        writer.Write(StereoSpeakerMask); // Channel 1 = Front Left; channel 2 = Front Right.
        writer.Write(source.SubFormat.ToByteArray());

        WriteFourCc(writer, "LIST");
        writer.Write((uint)listPayload.Length);
        writer.Write(listPayload);
        if ((listPayload.Length & 1) != 0)
            writer.Write((byte)0);

        WriteFourCc(writer, "data");
        writer.Write(dataLength);
    }

    private static byte[] CreateInfoList(string title, string sourcePath, Guid subFormat)
    {
        string encoding = subFormat == PcmSubFormat ? "PCM" : "IEEE float";
        using (MemoryStream memory = new MemoryStream())
        using (BinaryWriter writer = new BinaryWriter(memory, Encoding.ASCII, true))
        {
            WriteFourCc(writer, "INFO");
            WriteInfoString(writer, "INAM", CleanInfoText(title));
            WriteInfoString(writer, "ISFT", "DUNGU COREO mono converter");
            WriteInfoString(writer, "ICMT",
                "Channel order: 1=YIN reverse mono, 2=YAN forward mono. "
                + "Derived from mono source: " + Path.GetFileName(sourcePath)
                + ". Both channels derive from this one " + encoding + " input.");
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

    private static void ReadExactly(Stream stream, byte[] buffer, int count)
    {
        int offset = 0;
        while (offset < count)
        {
            int read = stream.Read(buffer, offset, count - offset);
            if (read == 0)
                throw new EndOfStreamException("The source data chunk ended before its declared length.");
            offset += read;
        }
    }

    private static string ReadFourCc(BinaryReader reader)
    {
        byte[] bytes = reader.ReadBytes(4);
        if (bytes.Length != 4)
            throw new EndOfStreamException("A RIFF chunk identifier is incomplete.");
        return Encoding.ASCII.GetString(bytes);
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

if ($null -eq ('CoreoMonoWavConverter' -as [type])) {
    Add-Type -TypeDefinition $csharpCode -ErrorAction Stop
}

[CoreoMonoWavConverter]::Convert($SourcePath, $OutputPath, $Title) | Format-List
