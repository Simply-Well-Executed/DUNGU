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

# Creates a derived quad file from interleaved stereo PCM16:
#   channel 1 = YIN, source L in reverse time
#   channel 2 = YIN, source R in reverse time
#   channel 3 = YAN, source L forward
#   channel 4 = YAN, source R forward
# The source is never changed. The extra channels are derived copies, not
# independent captured inputs.

$csharpCode = @'
using System;
using System.IO;
using System.Text;

public sealed class YinYanQuadReport
{
    public string SourcePath { get; set; }
    public string OutputPath { get; set; }
    public uint SampleRate { get; set; }
    public long Frames { get; set; }
    public long DataBytes { get; set; }
    public int Channels { get; set; }
    public string ChannelMap { get; set; }
}

public static class CoreoStereoToQuadConverter
{
    private const ushort WaveFormatPcm = 1;
    private const ushort WaveFormatExtensible = 0xFFFE;
    private const ushort OutputChannels = 4;
    private const ushort OutputBitsPerSample = 16;
    private const ushort OutputBlockAlign = OutputChannels * (OutputBitsPerSample / 8);
    private const uint QuadSpeakerMask = 0x00000033; // FL | FR | BL | BR
    private const int FramesPerBlock = 8192;

    private sealed class SourceWave
    {
        internal string Path;
        internal long DataOffset;
        internal uint DataLength;
        internal uint SampleRate;
        internal ushort Channels;
        internal ushort FormatTag;
        internal ushort BitsPerSample;
        internal ushort BlockAlign;
    }

    public static YinYanQuadReport Convert(string sourcePath, string outputPath, string title)
    {
        if (String.IsNullOrWhiteSpace(sourcePath))
            throw new ArgumentException("A source WAV path is required.", "sourcePath");
        if (String.IsNullOrWhiteSpace(outputPath))
            throw new ArgumentException("An output WAV path is required.", "outputPath");
        if (!BitConverter.IsLittleEndian)
            throw new PlatformNotSupportedException("This converter expects little-endian PCM samples.");

        string sourceFullPath = System.IO.Path.GetFullPath(sourcePath);
        string outputFullPath = System.IO.Path.GetFullPath(outputPath);
        if (String.Equals(sourceFullPath, outputFullPath, StringComparison.OrdinalIgnoreCase))
            throw new IOException("Source and output paths must be different.");
        if (File.Exists(outputFullPath))
            throw new IOException("Refusing to overwrite an existing output file: " + outputFullPath);

        SourceWave source = InspectStereoPcm16(sourceFullPath);
        if (source.DataLength % 4 != 0)
            throw new InvalidDataException("Stereo PCM16 data must contain whole L/R sample frames.");

        long frames = source.DataLength / 4L;
        long outputDataLength = checked(frames * OutputBlockAlign);
        if (outputDataLength > UInt32.MaxValue)
            throw new InvalidDataException("The converted data exceeds the classic RIFF 4 GiB limit.");

        byte[] listPayload = CreateInfoList(title, sourceFullPath);
        long listPaddedLength = checked(listPayload.Length + (listPayload.Length & 1));
        long outputFileLength = checked(76L + listPaddedLength + outputDataLength);
        long riffSize = outputFileLength - 8L;
        if (riffSize > UInt32.MaxValue)
            throw new InvalidDataException("The converted file exceeds the classic RIFF 4 GiB limit.");

        bool outputCreated = false;
        try
        {
            using (FileStream input = new FileStream(sourceFullPath, FileMode.Open, FileAccess.Read, FileShare.Read))
            using (FileStream output = new FileStream(outputFullPath, FileMode.CreateNew, FileAccess.Write, FileShare.Read,
                65536, FileOptions.SequentialScan))
            using (BinaryWriter writer = new BinaryWriter(output, Encoding.ASCII, true))
            {
                outputCreated = true;
                WriteOutputHeader(writer, source.SampleRate, (uint)riffSize,
                    (uint)outputDataLength, listPayload);

                byte[] reverseInput = new byte[FramesPerBlock * source.BlockAlign];
                byte[] forwardInput = new byte[FramesPerBlock * source.BlockAlign];
                byte[] outputBlock = new byte[FramesPerBlock * OutputBlockAlign];
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
                        int targetOffset = frame * OutputBlockAlign;

                        // YIN is a time-reversed stereo pair.
                        CopySample(reverseInput, reverseOffset, outputBlock, targetOffset);
                        CopySample(reverseInput, reverseOffset + 2, outputBlock, targetOffset + 2);

                        // YAN is the original forward stereo pair.
                        CopySample(forwardInput, forwardOffset, outputBlock, targetOffset + 4);
                        CopySample(forwardInput, forwardOffset + 2, outputBlock, targetOffset + 6);
                    }

                    writer.Write(outputBlock, 0, checked(blockFrames * OutputBlockAlign));
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

        return new YinYanQuadReport
        {
            SourcePath = sourceFullPath,
            OutputPath = outputFullPath,
            SampleRate = source.SampleRate,
            Frames = frames,
            DataBytes = outputDataLength,
            Channels = OutputChannels,
            ChannelMap = "1=YIN reverse L, 2=YIN reverse R, 3=YAN forward L, 4=YAN forward R"
        };
    }

    private static SourceWave InspectStereoPcm16(string path)
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
            ushort formatTag = 0;
            ushort channels = 0;
            uint sampleRate = 0;
            uint byteRate = 0;
            ushort blockAlign = 0;
            ushort bitsPerSample = 0;
            long dataOffset = 0;
            uint dataLength = 0;
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
                    if (sawFormat || chunkSize < 16)
                        throw new InvalidDataException("The source fmt chunk is missing, repeated, or too short.");
                    formatTag = reader.ReadUInt16();
                    channels = reader.ReadUInt16();
                    sampleRate = reader.ReadUInt32();
                    byteRate = reader.ReadUInt32();
                    blockAlign = reader.ReadUInt16();
                    bitsPerSample = reader.ReadUInt16();
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
                throw new InvalidDataException("The source data chunk must be final so its audio boundary is certain.");
            if (formatTag != WaveFormatPcm || channels != 2 || bitsPerSample != 16
                || blockAlign != 4 || sampleRate == 0 || byteRate != sampleRate * blockAlign)
                throw new InvalidDataException("This conversion requires stereo, 16-bit PCM WAVE input.");

            return new SourceWave
            {
                Path = path,
                DataOffset = dataOffset,
                DataLength = dataLength,
                SampleRate = sampleRate,
                Channels = channels,
                FormatTag = formatTag,
                BitsPerSample = bitsPerSample,
                BlockAlign = blockAlign
            };
        }
    }

    private static void WriteOutputHeader(BinaryWriter writer, uint sampleRate, uint riffSize,
        uint dataLength, byte[] listPayload)
    {
        WriteFourCc(writer, "RIFF");
        writer.Write(riffSize);
        WriteFourCc(writer, "WAVE");

        // WAVEFORMATEXTENSIBLE describes four channels and a speaker layout.
        WriteFourCc(writer, "fmt ");
        writer.Write((uint)40);
        writer.Write(WaveFormatExtensible);
        writer.Write(OutputChannels);
        writer.Write(sampleRate);
        writer.Write(checked(sampleRate * OutputBlockAlign));
        writer.Write(OutputBlockAlign);
        writer.Write(OutputBitsPerSample);
        writer.Write((ushort)22); // cbSize
        writer.Write(OutputBitsPerSample); // valid bits
        writer.Write(QuadSpeakerMask);
        writer.Write(new Guid("00000001-0000-0010-8000-00AA00389B71").ToByteArray()); // PCM subtype

        WriteFourCc(writer, "LIST");
        writer.Write((uint)listPayload.Length);
        writer.Write(listPayload);
        if ((listPayload.Length & 1) != 0)
            writer.Write((byte)0);

        WriteFourCc(writer, "data");
        writer.Write(dataLength);
    }

    private static byte[] CreateInfoList(string title, string sourcePath)
    {
        using (MemoryStream memory = new MemoryStream())
        using (BinaryWriter writer = new BinaryWriter(memory, Encoding.ASCII, true))
        {
            WriteFourCc(writer, "INFO");
            WriteInfoString(writer, "INAM", CleanInfoText(title));
            WriteInfoString(writer, "ISFT", "DUNGU COREO YIN-YAN converter");
            WriteInfoString(writer, "ICMT",
                "Channel order: 1=YIN reverse L, 2=YIN reverse R, 3=YAN forward L, 4=YAN forward R. "
                + "Derived from stereo source: " + Path.GetFileName(sourcePath)
                + ". Channels 3 and 4 are transformed copies, not separate captured inputs.");
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

    private static void CopySample(byte[] source, int sourceOffset, byte[] destination, int destinationOffset)
    {
        destination[destinationOffset] = source[sourceOffset];
        destination[destinationOffset + 1] = source[sourceOffset + 1];
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

if ($null -eq ('CoreoStereoToQuadConverter' -as [type])) {
    Add-Type -TypeDefinition $csharpCode -ErrorAction Stop
}

[CoreoStereoToQuadConverter]::Convert($SourcePath, $OutputPath, $Title) | Format-List
