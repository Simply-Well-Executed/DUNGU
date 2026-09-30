[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $PreviewPath,

    [string] $RawPcmPath,

    [int] $SampleRate = 44100,

    [short] $Channels = 2,

    [short] $BitsPerSample = 16
)

$csharpCode = @"
using System;
using System.IO;
using System.Text;

public sealed class RiffWaveReport
{
    public string Path { get; set; }
    public long FileLength { get; set; }
    public uint StoredRiffSize { get; set; }
    public uint RecomputedRiffSize { get; set; }
    public uint StoredDataSize { get; set; }
    public uint RecomputedDataSize { get; set; }
    public long DataChunkHeaderOffset { get; set; }
    public long DataPayloadOffset { get; set; }
    public ushort FormatTag { get; set; }
    public ushort Channels { get; set; }
    public uint SampleRate { get; set; }
    public uint ByteRate { get; set; }
    public ushort BlockAlign { get; set; }
    public ushort BitsPerSample { get; set; }
    public bool SizesMatch { get; set; }
}

public static class WavHeader
{
    private static string ReadFourCc(BinaryReader reader)
    {
        byte[] bytes = reader.ReadBytes(4);
        if (bytes.Length != 4)
            throw new EndOfStreamException("A RIFF chunk identifier is incomplete.");
        return Encoding.ASCII.GetString(bytes);
    }

    public static RiffWaveReport InspectFinalDataChunk(string path)
    {
        string fullPath = Path.GetFullPath(path);

        using (FileStream stream = new FileStream(
            fullPath, FileMode.Open, FileAccess.Read, FileShare.Read))
        using (BinaryReader reader = new BinaryReader(stream, Encoding.ASCII, true))
        {
            if (stream.Length < 12)
                throw new InvalidDataException("The file is too short for RIFF/WAVE.");
            if (stream.Length - 8 > uint.MaxValue)
                throw new InvalidDataException("Classic RIFF size fields overflow; RF64 is required.");
            if (ReadFourCc(reader) != "RIFF")
                throw new InvalidDataException("The file does not start with RIFF.");

            uint storedRiffSize = reader.ReadUInt32();
            if (ReadFourCc(reader) != "WAVE")
                throw new InvalidDataException("The RIFF form type is not WAVE.");

            ushort formatTag = 0;
            ushort channels = 0;
            uint sampleRate = 0;
            uint byteRate = 0;
            ushort blockAlign = 0;
            ushort bitsPerSample = 0;
            bool sawFmt = false;

            long position = 12;
            while (position <= stream.Length - 8)
            {
                stream.Position = position;
                string chunkId = ReadFourCc(reader);
                uint chunkSize = reader.ReadUInt32();
                long payloadOffset = stream.Position;
                long declaredEnd = checked(payloadOffset + (long)chunkSize);

                if (chunkId == "fmt ")
                {
                    if (chunkSize < 16 || declaredEnd > stream.Length)
                        throw new InvalidDataException("The fmt chunk is incomplete.");

                    formatTag = reader.ReadUInt16();
                    channels = reader.ReadUInt16();
                    sampleRate = reader.ReadUInt32();
                    byteRate = reader.ReadUInt32();
                    blockAlign = reader.ReadUInt16();
                    bitsPerSample = reader.ReadUInt16();

                    if (channels == 0 || sampleRate == 0 || blockAlign == 0)
                        throw new InvalidDataException("The fmt chunk has invalid audio dimensions.");
                    sawFmt = true;
                }
                else if (chunkId == "data")
                {
                    if (!sawFmt)
                        throw new InvalidDataException("A usable fmt chunk must precede data.");

                    long physicalTail = stream.Length - payloadOffset;
                    long dataSizeWithPad = chunkSize + (chunkSize & 1L);

                    // Require the data chunk to be final, so later metadata is
                    // never accidentally counted as audio.
                    if (physicalTail != dataSizeWithPad)
                        throw new InvalidDataException(
                            "The data chunk is not verifiably final; refusing to guess its size.");
                    if (chunkSize % blockAlign != 0)
                        throw new InvalidDataException("The data chunk does not contain whole audio frames.");

                    uint recomputedRiffSize = checked((uint)(stream.Length - 8));
                    uint recomputedDataSize = checked((uint)(physicalTail - (chunkSize & 1L)));

                    return new RiffWaveReport
                    {
                        Path = fullPath,
                        FileLength = stream.Length,
                        StoredRiffSize = storedRiffSize,
                        RecomputedRiffSize = recomputedRiffSize,
                        StoredDataSize = chunkSize,
                        RecomputedDataSize = recomputedDataSize,
                        DataChunkHeaderOffset = position,
                        DataPayloadOffset = payloadOffset,
                        FormatTag = formatTag,
                        Channels = channels,
                        SampleRate = sampleRate,
                        ByteRate = byteRate,
                        BlockAlign = blockAlign,
                        BitsPerSample = bitsPerSample,
                        SizesMatch = storedRiffSize == recomputedRiffSize
                            && chunkSize == recomputedDataSize
                    };
                }

                long nextPosition = checked(declaredEnd + (chunkSize & 1L));
                if (nextPosition > stream.Length)
                    throw new InvalidDataException("A RIFF chunk extends past end-of-file.");
                position = nextPosition;
            }

            throw new InvalidDataException("No final data chunk was found.");
        }
    }

    public static byte[] CreatePcmHeader(
        int sampleRate, short channels, short bitsPerSample, long dataLength)
    {
        if (sampleRate <= 0)
            throw new ArgumentOutOfRangeException("sampleRate");
        if (channels <= 0)
            throw new ArgumentOutOfRangeException("channels");
        if (bitsPerSample <= 0 || bitsPerSample % 8 != 0)
            throw new ArgumentOutOfRangeException("bitsPerSample");
        if (dataLength < 0 || dataLength > uint.MaxValue - 36L)
            throw new ArgumentOutOfRangeException("dataLength",
                "Classic RIFF/WAVE supports at most 4 GiB minus its header.");

        int bytesPerSample = bitsPerSample / 8;
        int blockAlignValue = checked(channels * bytesPerSample);
        if (blockAlignValue > ushort.MaxValue)
            throw new ArgumentOutOfRangeException("channels");

        ushort blockAlign = (ushort)blockAlignValue;
        if (dataLength % blockAlign != 0)
            throw new ArgumentException(
                "PCM data length must contain a whole number of sample frames.",
                "dataLength");

        long byteRateValue = checked((long)sampleRate * blockAlign);
        if (byteRateValue > uint.MaxValue)
            throw new ArgumentOutOfRangeException("sampleRate");

        byte[] header = new byte[44];
        using (MemoryStream stream = new MemoryStream(header))
        using (BinaryWriter writer = new BinaryWriter(stream, Encoding.ASCII))
        {
            writer.Write(Encoding.ASCII.GetBytes("RIFF"));
            writer.Write(checked((uint)(36L + dataLength)));
            writer.Write(Encoding.ASCII.GetBytes("WAVE"));
            writer.Write(Encoding.ASCII.GetBytes("fmt "));
            writer.Write((uint)16);
            writer.Write((ushort)1); // WAVE_FORMAT_PCM
            writer.Write((ushort)channels);
            writer.Write((uint)sampleRate);
            writer.Write((uint)byteRateValue);
            writer.Write(blockAlign);
            writer.Write((ushort)bitsPerSample);
            writer.Write(Encoding.ASCII.GetBytes("data"));
            writer.Write((uint)dataLength);
        }

        return header;
    }
}
"@

Add-Type -TypeDefinition $csharpCode

$report = [WavHeader]::InspectFinalDataChunk($PreviewPath)
$report | Format-List

if (-not $report.SizesMatch) {
    Write-Warning 'Stored RIFF/data size fields differ from their recomputed values.'
}

if ($RawPcmPath) {
    $dataLength = (Get-Item -LiteralPath $RawPcmPath).Length
    $header = [WavHeader]::CreatePcmHeader(
        $SampleRate, $Channels, $BitsPerSample, $dataLength)
    $headerHex = ($header | ForEach-Object { $_.ToString('X2') }) -join ' '

    Write-Host "44-byte PCM RIFF header for $dataLength raw bytes:"
    Write-Host $headerHex
}
