#requires -Version 7.0
#requires -PSEdition Core
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateRange(1, 2147483647)]
    [int[]]$ProcessId,

    [switch]$ExcludeProcessTree,

    [ValidateRange(0, 86400)]
    [int]$DurationSeconds = 0,

    [ValidateRange(0, 100)]
    [int]$ReplayPasses = 0,

    [switch]$EnablePipe,

    [ValidateRange(1, 64)]
    [int]$PipeQueuePackets = 1,

    [switch]$CompileOnly,

    [switch]$SelfTest
)

$serverCode = @'
using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.IO.Compression;
using System.IO.Pipes;
using Microsoft.Win32.SafeHandles;
using System.Numerics;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Threading;
using System.Threading.Tasks;

namespace Dungu.ProcessLoopback
{
    [ComImport, Guid("72A22D78-CDE4-431D-B8CC-843A71199B6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IActivateAudioInterfaceAsyncOperation
    {
        [PreserveSig]
        int GetActivateResult(out int activateResult, [MarshalAs(UnmanagedType.IUnknown)] out object activatedInterface);
    }

    [ComVisible(true), Guid("41D949AB-9862-444A-80F6-C261334DA5EB"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IActivateAudioInterfaceCompletionHandler
    {
        [PreserveSig]
        int ActivateCompleted(IActivateAudioInterfaceAsyncOperation activationOperation);
    }

    [ComVisible(true), Guid("94EA2B94-E9CC-49E0-C0FF-EE64CA8F5B90"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IAgileObject
    {
    }

    [ComImport, Guid("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IAudioClient
    {
        [PreserveSig] int Initialize(int shareMode, int streamFlags, long bufferDuration, long periodicity, IntPtr format, IntPtr audioSessionGuid);
        [PreserveSig] int GetBufferSize(out int bufferFrames);
        [PreserveSig] int GetStreamLatency(out long latency);
        [PreserveSig] int GetCurrentPadding(out int paddingFrames);
        [PreserveSig] int IsFormatSupported(int shareMode, IntPtr format, out IntPtr closestMatch);
        [PreserveSig] int GetMixFormat(out IntPtr deviceFormat);
        [PreserveSig] int GetDevicePeriod(out long defaultPeriod, out long minimumPeriod);
        [PreserveSig] int Start();
        [PreserveSig] int Stop();
        [PreserveSig] int Reset();
        [PreserveSig] int SetEventHandle(IntPtr eventHandle);
        [PreserveSig] int GetService(ref Guid serviceId, [MarshalAs(UnmanagedType.IUnknown)] out object service);
    }

    [ComImport, Guid("C8ADBD64-E71E-48A0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IAudioCaptureClient
    {
        [PreserveSig] int GetBuffer(out IntPtr data, out int frames, out int flags, out long devicePosition, out long qpcPosition);
        [PreserveSig] int ReleaseBuffer(int frames);
        [PreserveSig] int GetNextPacketSize(out int frames);
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct AudioClientProcessLoopbackParams
    {
        public uint TargetProcessId;
        public int ProcessLoopbackMode;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct AudioClientActivationParams
    {
        public int ActivationType;
        public AudioClientProcessLoopbackParams ProcessLoopbackParams;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 2)]
    public struct WaveFormatEx
    {
        public ushort FormatTag;
        public ushort Channels;
        public uint SamplesPerSecond;
        public uint AverageBytesPerSecond;
        public ushort BlockAlign;
        public ushort BitsPerSample;
        public ushort ExtraSize;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 2)]
    public struct WaveFormatExtensible
    {
        public WaveFormatEx Format;
        public ushort ValidBitsPerSample;
        public uint ChannelMask;
        public Guid SubFormat;
    }

    [ComVisible(true), ClassInterface(ClassInterfaceType.None)]
    public sealed class ActivationHandler : IActivateAudioInterfaceCompletionHandler, IAgileObject
    {
        private readonly TaskCompletionSource<IAudioClient> _completion =
            new TaskCompletionSource<IAudioClient>(TaskCreationOptions.RunContinuationsAsynchronously);

        public Task<IAudioClient> Completion
        {
            get { return _completion.Task; }
        }

        public int ActivateCompleted(IActivateAudioInterfaceAsyncOperation activationOperation)
        {
            try
            {
                if (activationOperation == null)
                    throw new ArgumentNullException("activationOperation");

                int activationResult;
                object activatedInterface;
                NativeMethods.ThrowIfFailed(
                    activationOperation.GetActivateResult(out activationResult, out activatedInterface),
                    "IActivateAudioInterfaceAsyncOperation.GetActivateResult");
                NativeMethods.ThrowIfFailed(activationResult, "Process loopback activation");

                IAudioClient audioClient = activatedInterface as IAudioClient;
                if (audioClient == null)
                    throw new InvalidCastException("Activation did not return IAudioClient.");

                _completion.TrySetResult(audioClient);
            }
            catch (Exception error)
            {
                _completion.TrySetException(error);
            }

            return 0;
        }
    }

    internal static class NativeMethods
    {
        internal const int ProcessLoopbackActivationType = 1;
        internal const int IncludeTargetProcessTree = 0;
        internal const int ExcludeTargetProcessTree = 1;
        internal const int WaveFormatPcm = 1;
        internal const int WaveFormatIeeeFloat = 3;
        internal const int WaveFormatExtensible = 0xFFFE;
        internal const int AudioClientStreamFlagsLoopback = 0x00020000;
        internal const int AudioClientStreamFlagsAutoConvertPcm = unchecked((int)0x80000000u);
        internal const int AudioClientBufferFlagSilent = 0x00000002;

        internal static readonly Guid PcmSubFormat = new Guid("00000001-0000-0010-8000-00AA00389B71");
        internal static readonly Guid IeeeFloatSubFormat = new Guid("00000003-0000-0010-8000-00AA00389B71");
        internal static readonly Guid AudioClientInterfaceId = new Guid("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2");
        internal static readonly Guid AudioCaptureClientInterfaceId = new Guid("C8ADBD64-E71E-48A0-A4DE-185C395CD317");

        [StructLayout(LayoutKind.Sequential)]
        private struct SecurityAttributes
        {
            public int Length;
            public IntPtr SecurityDescriptor;
            public int InheritHandle;
        }

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, EntryPoint = "ConvertStringSecurityDescriptorToSecurityDescriptorW", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(
            string securityDescriptor,
            uint revision,
            out IntPtr convertedDescriptor,
            out uint descriptorSize);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, EntryPoint = "CreateNamedPipeW", SetLastError = true)]
        private static extern SafePipeHandle CreateNamedPipe(
            string pipeName,
            uint openMode,
            uint pipeMode,
            uint maxInstances,
            uint outputBufferSize,
            uint inputBufferSize,
            uint defaultTimeout,
            ref SecurityAttributes securityAttributes);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr LocalFree(IntPtr memory);

        [DllImport("Mmdevapi.dll", CharSet = CharSet.Unicode, ExactSpelling = true, PreserveSig = true)]
        internal static extern int ActivateAudioInterfaceAsync(
            [MarshalAs(UnmanagedType.LPWStr)] string deviceInterfacePath,
            [MarshalAs(UnmanagedType.LPStruct)] Guid interfaceId,
            IntPtr activationParams,
            [MarshalAs(UnmanagedType.Interface)] IActivateAudioInterfaceCompletionHandler completionHandler,
            out IActivateAudioInterfaceAsyncOperation activationOperation);

        internal static NamedPipeServerStream CreateLocalCurrentUserPipe(string pipeName)
        {
            using (WindowsIdentity identity = WindowsIdentity.GetCurrent())
            {
                SecurityIdentifier userSid = identity.User;
                if (userSid == null)
                    throw new InvalidOperationException("The current Windows identity has no user SID.");

                string securityDescriptor = "D:P(A;;GA;;;" + userSid.Value + ")(A;;GA;;;SY)";
                IntPtr nativeDescriptor = IntPtr.Zero;
                SafePipeHandle pipeHandle = null;
                try
                {
                    uint descriptorSize;
                    if (!ConvertStringSecurityDescriptorToSecurityDescriptor(
                        securityDescriptor,
                        1,
                        out nativeDescriptor,
                        out descriptorSize))
                    {
                        throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not create the named-pipe access descriptor.");
                    }

                    var attributes = new SecurityAttributes
                    {
                        Length = Marshal.SizeOf(typeof(SecurityAttributes)),
                        SecurityDescriptor = nativeDescriptor,
                        InheritHandle = 0
                    };

                    const uint PipeAccessOutbound = 0x00000002;
                    const uint FileFlagOverlapped = 0x40000000;
                    const uint PipeWait = 0x00000000;
                    const uint PipeRejectRemoteClients = 0x00000008;
                    pipeHandle = CreateNamedPipe(
                        @"\\.\pipe\" + pipeName,
                        PipeAccessOutbound | FileFlagOverlapped,
                        PipeWait | PipeRejectRemoteClients,
                        1,
                        0,
                        0,
                        0,
                        ref attributes);
                    if (pipeHandle == null || pipeHandle.IsInvalid)
                        throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not create the local named pipe.");

                    var stream = new NamedPipeServerStream(PipeDirection.Out, true, false, pipeHandle);
                    pipeHandle = null;
                    return stream;
                }
                finally
                {
                    if (nativeDescriptor != IntPtr.Zero)
                        LocalFree(nativeDescriptor);
                    if (pipeHandle != null)
                        pipeHandle.Dispose();
                }
            }
        }

        internal static int PropVariantSize
        {
            get { return IntPtr.Size == 8 ? 24 : 16; }
        }

        internal static IntPtr CreateActivationPropVariant(uint targetProcessId, bool includeProcessTree, out IntPtr activationData)
        {
            activationData = IntPtr.Zero;
            IntPtr propVariant = IntPtr.Zero;
            int activationSize = Marshal.SizeOf(typeof(AudioClientActivationParams));
            AudioClientActivationParams parameters = new AudioClientActivationParams
            {
                ActivationType = ProcessLoopbackActivationType,
                ProcessLoopbackParams = new AudioClientProcessLoopbackParams
                {
                    TargetProcessId = targetProcessId,
                    ProcessLoopbackMode = includeProcessTree ? IncludeTargetProcessTree : ExcludeTargetProcessTree
                }
            };

            try
            {
                activationData = Marshal.AllocHGlobal(activationSize);
                Marshal.StructureToPtr(parameters, activationData, false);

                propVariant = Marshal.AllocHGlobal(PropVariantSize);
                for (int index = 0; index < PropVariantSize; index++)
                    Marshal.WriteByte(propVariant, index, 0);

                Marshal.WriteInt16(propVariant, 0, 65); // VT_BLOB
                Marshal.WriteInt32(propVariant, 8, activationSize);
                Marshal.WriteIntPtr(propVariant, IntPtr.Size == 8 ? 16 : 12, activationData);
                return propVariant;
            }
            catch
            {
                if (propVariant != IntPtr.Zero)
                    Marshal.FreeHGlobal(propVariant);
                if (activationData != IntPtr.Zero)
                    Marshal.FreeHGlobal(activationData);
                activationData = IntPtr.Zero;
                throw;
            }
        }

        internal static void ThrowIfFailed(int result, string operation)
        {
            if (result < 0)
                throw new COMException(operation + " failed with HRESULT 0x" + result.ToString("X8") + ".", result);
        }
    }

    internal sealed class AudioSampleFormat
    {
        private readonly int _encoding;
        private readonly int _channels;
        private readonly int _containerBits;
        private readonly int _validBits;
        private readonly int _blockAlign;
        private readonly int _bytesPerSample;
        private readonly int _sampleRate;

        private AudioSampleFormat(int encoding, int channels, int containerBits, int validBits, int blockAlign, int sampleRate)
        {
            if (channels <= 0)
                throw new NotSupportedException("The mix format reports no audio channels.");
            if (sampleRate <= 0)
                throw new NotSupportedException("The mix format reports an invalid sample rate.");
            if (containerBits <= 0 || containerBits % 8 != 0)
                throw new NotSupportedException("The mix format has an unsupported sample container size.");
            if (validBits <= 0 || validBits > containerBits)
                throw new NotSupportedException("The mix format has an invalid valid-bits-per-sample value.");

            _encoding = encoding;
            _channels = channels;
            _containerBits = containerBits;
            _validBits = validBits;
            _blockAlign = blockAlign;
            _bytesPerSample = containerBits / 8;
            _sampleRate = sampleRate;

            if (blockAlign < channels * _bytesPerSample)
                throw new NotSupportedException("The mix format block alignment is smaller than its sample data.");

            if (encoding == NativeMethods.WaveFormatPcm)
            {
                if (containerBits != 8 && containerBits != 16 && containerBits != 24 && containerBits != 32)
                    throw new NotSupportedException("PCM mix formats must use 8, 16, 24, or 32-bit containers.");
                if (containerBits == 8 && validBits != 8)
                    throw new NotSupportedException("Sub-byte-valid 8-bit PCM is not supported.");
            }
            else if (encoding == NativeMethods.WaveFormatIeeeFloat)
            {
                if ((containerBits != 32 && containerBits != 64) || validBits != containerBits)
                    throw new NotSupportedException("IEEE float mix formats must use 32- or 64-bit samples.");
            }
            else
            {
                throw new NotSupportedException("The audio mix format is not PCM or IEEE float.");
            }
        }

        internal int Encoding { get { return _encoding; } }
        internal int Channels { get { return _channels; } }
        internal int ContainerBits { get { return _containerBits; } }
        internal int ValidBits { get { return _validBits; } }
        internal int BlockAlign { get { return _blockAlign; } }
        internal int SampleRate { get { return _sampleRate; } }

        internal static AudioSampleFormat FromNative(IntPtr formatPointer)
        {
            WaveFormatEx format = (WaveFormatEx)Marshal.PtrToStructure(formatPointer, typeof(WaveFormatEx));
            int encoding = format.FormatTag;
            int validBits = format.BitsPerSample;

            if (format.FormatTag == NativeMethods.WaveFormatExtensible)
            {
                if (format.ExtraSize < 22)
                    throw new NotSupportedException("The extensible mix format is missing its subformat data.");

                WaveFormatExtensible extensible =
                    (WaveFormatExtensible)Marshal.PtrToStructure(formatPointer, typeof(WaveFormatExtensible));
                if (extensible.SubFormat == NativeMethods.PcmSubFormat)
                    encoding = NativeMethods.WaveFormatPcm;
                else if (extensible.SubFormat == NativeMethods.IeeeFloatSubFormat)
                    encoding = NativeMethods.WaveFormatIeeeFloat;
                else
                    throw new NotSupportedException("The extensible mix format uses an unsupported subformat.");

                if (extensible.ValidBitsPerSample != 0)
                    validBits = extensible.ValidBitsPerSample;
            }

            return new AudioSampleFormat(
                encoding,
                format.Channels,
                format.BitsPerSample,
                validBits,
                format.BlockAlign,
                (int)format.SamplesPerSecond);
        }

        internal static AudioSampleFormat FromTimeline(AudioTimelineEntry entry)
        {
            return new AudioSampleFormat(
                entry.FormatTag,
                entry.Channels,
                entry.BitsPerSample,
                entry.ValidBitsPerSample,
                entry.BlockAlign,
                entry.SampleRate);
        }

        internal static AudioSampleFormat CreateForTesting(
            int encoding,
            int channels,
            int containerBits,
            int validBits,
            int blockAlign,
            int sampleRate = 48000)
        {
            return new AudioSampleFormat(encoding, channels, containerBits, validBits, blockAlign, sampleRate);
        }

        internal static AudioSampleFormat CreateProcessLoopbackCaptureFormat()
        {
            // The process-loopback virtual client can return E_NOTIMPL from GetMixFormat.
            // Use the explicit PCM format used by Microsoft's ApplicationLoopback sample.
            return new AudioSampleFormat(
                NativeMethods.WaveFormatPcm,
                2,
                16,
                16,
                4,
                44100);
        }

        internal void ConvertToFloat(IntPtr data, int frames, float[] destination, int destinationOffset)
        {
            if (frames < 0)
                throw new ArgumentOutOfRangeException("frames");
            if (destination == null)
                throw new ArgumentNullException("destination");

            int sampleCount = checked(frames * _channels);
            if (destinationOffset < 0 || destinationOffset > destination.Length - sampleCount)
                throw new ArgumentOutOfRangeException("destinationOffset");
            if (frames > 0 && data == IntPtr.Zero)
                throw new ArgumentNullException("data");

            for (int frame = 0; frame < frames; frame++)
            {
                int frameOffset = checked(frame * _blockAlign);
                for (int channel = 0; channel < _channels; channel++)
                {
                    int sampleOffset = checked(frameOffset + channel * _bytesPerSample);
                    destination[destinationOffset + frame * _channels + channel] =
                        ReadSample(IntPtr.Add(data, sampleOffset));
                }
            }
        }

        internal void ConvertToFloat(byte[] source, int frames, float[] destination, int destinationOffset)
        {
            if (source == null)
                throw new ArgumentNullException("source");
            if (frames < 0)
                throw new ArgumentOutOfRangeException("frames");
            if (destination == null)
                throw new ArgumentNullException("destination");

            int sampleCount = checked(frames * _channels);
            int byteCount = checked(frames * _blockAlign);
            if (source.Length < byteCount)
                throw new ArgumentException("The source block is shorter than the declared audio frames.", "source");
            if (destinationOffset < 0 || destinationOffset > destination.Length - sampleCount)
                throw new ArgumentOutOfRangeException("destinationOffset");

            for (int frame = 0; frame < frames; frame++)
            {
                int frameOffset = checked(frame * _blockAlign);
                for (int channel = 0; channel < _channels; channel++)
                {
                    int sampleOffset = checked(frameOffset + channel * _bytesPerSample);
                    destination[destinationOffset + frame * _channels + channel] = ReadSample(source, sampleOffset);
                }
            }
        }

        internal float MeasurePeak(IntPtr data, int frames)
        {
            if (frames < 0)
                throw new ArgumentOutOfRangeException("frames");
            if (frames == 0)
                return 0;
            if (data == IntPtr.Zero)
                throw new ArgumentNullException("data");

            float peak = 0;
            for (int frame = 0; frame < frames; frame++)
            {
                int frameOffset = checked(frame * _blockAlign);
                for (int channel = 0; channel < _channels; channel++)
                {
                    int offset = checked(frameOffset + channel * _bytesPerSample);
                    float sample = ReadSample(IntPtr.Add(data, offset));
                    if (!Single.IsNaN(sample) && !Single.IsInfinity(sample))
                    {
                        float magnitude = Math.Abs(sample);
                        if (magnitude > peak)
                            peak = magnitude;
                    }
                }
            }
            return peak;
        }

        internal float MeasurePeak(float[] samples, int sampleCount)
        {
            if (samples == null)
                throw new ArgumentNullException("samples");
            if (sampleCount < 0 || sampleCount > samples.Length)
                throw new ArgumentOutOfRangeException("sampleCount");

            float peak = 0;
            for (int index = 0; index < sampleCount; index++)
            {
                float sample = samples[index];
                if (!Single.IsNaN(sample) && !Single.IsInfinity(sample))
                    peak = Math.Max(peak, Math.Abs(sample));
            }
            return peak;
        }

        internal float MeasurePeak(byte[] data, int dataOffset, int frames)
        {
            if (frames < 0)
                throw new ArgumentOutOfRangeException("frames");
            if (frames == 0)
                return 0;
            if (data == null)
                throw new ArgumentNullException("data");

            int byteCount = checked(frames * _blockAlign);
            if (dataOffset < 0 || dataOffset > data.Length - byteCount)
                throw new ArgumentOutOfRangeException("dataOffset");

            float peak = 0;
            for (int frame = 0; frame < frames; frame++)
            {
                int frameOffset = checked(dataOffset + frame * _blockAlign);
                for (int channel = 0; channel < _channels; channel++)
                {
                    int sampleOffset = checked(frameOffset + channel * _bytesPerSample);
                    float sample = ReadSample(data, sampleOffset);
                    if (!Single.IsNaN(sample) && !Single.IsInfinity(sample))
                    {
                        float magnitude = Math.Abs(sample);
                        if (magnitude > peak)
                            peak = magnitude;
                    }
                }
            }
            return peak;
        }

        private float ReadSample(IntPtr data)
        {
            if (_encoding == NativeMethods.WaveFormatIeeeFloat)
            {
                if (_containerBits == 32)
                    return BitConverter.Int32BitsToSingle(Marshal.ReadInt32(data));

                return (float)BitConverter.Int64BitsToDouble(Marshal.ReadInt64(data));
            }

            if (_containerBits == 8)
                return (Marshal.ReadByte(data) - 128) / 128.0f;

            int raw;
            if (_containerBits == 16)
                raw = Marshal.ReadInt16(data);
            else if (_containerBits == 24)
            {
                raw = Marshal.ReadByte(data)
                    | (Marshal.ReadByte(IntPtr.Add(data, 1)) << 8)
                    | (Marshal.ReadByte(IntPtr.Add(data, 2)) << 16);
                if ((raw & 0x00800000) != 0)
                    raw |= unchecked((int)0xFF000000);
            }
            else
                raw = Marshal.ReadInt32(data);

            int paddingBits = _containerBits - _validBits;
            if (paddingBits > 0)
                raw >>= paddingBits;

            return (float)(raw / Math.Pow(2.0, _validBits - 1));
        }

        private float ReadSample(byte[] data, int offset)
        {
            if (_encoding == NativeMethods.WaveFormatIeeeFloat)
            {
                if (_containerBits == 32)
                    return BitConverter.ToSingle(data, offset);

                return (float)BitConverter.ToDouble(data, offset);
            }

            if (_containerBits == 8)
                return (data[offset] - 128) / 128.0f;

            int raw;
            if (_containerBits == 16)
                raw = BitConverter.ToInt16(data, offset);
            else if (_containerBits == 24)
            {
                raw = data[offset]
                    | (data[offset + 1] << 8)
                    | (data[offset + 2] << 16);
                if ((raw & 0x00800000) != 0)
                    raw |= unchecked((int)0xFF000000);
            }
            else
                raw = BitConverter.ToInt32(data, offset);

            int paddingBits = _containerBits - _validBits;
            if (paddingBits > 0)
                raw >>= paddingBits;

            return (float)(raw / Math.Pow(2.0, _validBits - 1));
        }
    }

    public enum AudioStorageMode : byte
    {
        Raw = 0,
        ZlibRaw = 1,
        ZlibCompandedFloat32 = 2
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    public struct AudioTimelineEntry
    {
        public long Sequence;
        public long AbsoluteByteOffset;
        public long QpcPosition;
        public long DevicePosition;
        public int ProcessId;
        public int StoredByteLength;
        public int OriginalByteLength;
        public int FrameCount;
        public int Flags;
        public int SampleRate;
        public ushort Channels;
        public ushort BlockAlign;
        public ushort FormatTag;
        public byte BitsPerSample;
        public byte ValidBitsPerSample;
        public byte StorageMode;
        public byte CompandingApplied;
    }

    public static class AudioPipeProtocol
    {
        public const int HeaderSize = 64;
        public const ushort Version = 1;

        public static void ValidatePayload(AudioTimelineEntry entry, int payloadLength, AudioStorageMode storageMode)
        {
            if (entry.ProcessId <= 0 || entry.SampleRate <= 0 || entry.Channels == 0
                || entry.BlockAlign == 0 || entry.FrameCount <= 0)
                throw new ArgumentException("The pipe timeline metadata is incomplete.", "entry");
            if (payloadLength <= 0)
                throw new ArgumentOutOfRangeException("payloadLength");

            int decodedLength;
            switch (storageMode)
            {
                case AudioStorageMode.Raw:
                    decodedLength = checked(entry.FrameCount * entry.BlockAlign);
                    if (payloadLength != decodedLength || entry.CompandingApplied != 0)
                        throw new ArgumentException("A raw pipe payload must match the declared audio frames.", "payloadLength");
                    break;
                case AudioStorageMode.ZlibRaw:
                    decodedLength = checked(entry.FrameCount * entry.BlockAlign);
                    if (payloadLength >= decodedLength || entry.CompandingApplied != 0)
                        throw new ArgumentException("A ZLIB-raw payload must be smaller than its decoded audio.", "payloadLength");
                    break;
                case AudioStorageMode.ZlibCompandedFloat32:
                    decodedLength = checked(entry.FrameCount * entry.BlockAlign);
                    if (entry.FormatTag != NativeMethods.WaveFormatIeeeFloat
                        || entry.BitsPerSample != 32
                        || entry.ValidBitsPerSample != 32
                        || entry.BlockAlign != entry.Channels * sizeof(float)
                        || payloadLength >= decodedLength
                        || entry.CompandingApplied != 1)
                        throw new ArgumentException("The companded payload must describe a compressed float32 frame block.", "entry");
                    break;
                default:
                    throw new ArgumentOutOfRangeException("storageMode");
            }
        }

        public static byte[] CreateHeader(AudioTimelineEntry entry, int payloadLength)
        {
            AudioStorageMode storageMode = (AudioStorageMode)entry.StorageMode;
            ValidatePayload(entry, payloadLength, storageMode);

            var header = new byte[HeaderSize];
            header[0] = (byte)'D';
            header[1] = (byte)'N';
            header[2] = (byte)'G';
            header[3] = (byte)'U';
            BinaryPrimitives.WriteUInt16LittleEndian(header.AsSpan(4, 2), Version);
            BinaryPrimitives.WriteUInt16LittleEndian(header.AsSpan(6, 2), HeaderSize);
            BinaryPrimitives.WriteInt64LittleEndian(header.AsSpan(8, 8), entry.Sequence);
            BinaryPrimitives.WriteInt64LittleEndian(header.AsSpan(16, 8), entry.QpcPosition);
            BinaryPrimitives.WriteInt64LittleEndian(header.AsSpan(24, 8), entry.DevicePosition);
            BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(32, 4), unchecked((uint)entry.ProcessId));
            BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(36, 4), unchecked((uint)entry.SampleRate));
            BinaryPrimitives.WriteUInt16LittleEndian(header.AsSpan(40, 2), entry.Channels);
            BinaryPrimitives.WriteUInt16LittleEndian(header.AsSpan(42, 2), entry.FormatTag);
            BinaryPrimitives.WriteUInt16LittleEndian(header.AsSpan(44, 2), entry.BitsPerSample);
            BinaryPrimitives.WriteUInt16LittleEndian(header.AsSpan(46, 2), entry.ValidBitsPerSample);
            BinaryPrimitives.WriteUInt16LittleEndian(header.AsSpan(48, 2), entry.BlockAlign);
            header[50] = (byte)storageMode;
            header[51] = entry.CompandingApplied;
            BinaryPrimitives.WriteInt32LittleEndian(header.AsSpan(52, 4), entry.FrameCount);
            BinaryPrimitives.WriteInt32LittleEndian(header.AsSpan(56, 4), payloadLength);
            BinaryPrimitives.WriteInt32LittleEndian(header.AsSpan(60, 4), entry.Flags);
            return header;
        }
    }

    internal sealed class AudioPipePacket
    {
        internal readonly AudioTimelineEntry Timeline;
        internal readonly byte[] Payload;

        internal AudioPipePacket(AudioTimelineEntry timeline, byte[] payload)
        {
            Timeline = timeline;
            Payload = payload;
        }
    }

    internal sealed class BoundedAudioPipeQueue
    {
        private readonly object _gate = new object();
        private readonly Queue<AudioPipePacket> _items = new Queue<AudioPipePacket>();
        private readonly int _capacity;

        internal BoundedAudioPipeQueue(int capacity)
        {
            if (capacity <= 0)
                throw new ArgumentOutOfRangeException("capacity");
            _capacity = capacity;
        }

        internal bool EnqueueDroppingOldest(AudioPipePacket packet)
        {
            if (packet == null)
                throw new ArgumentNullException("packet");

            lock (_gate)
            {
                bool droppedOldest = _items.Count >= _capacity;
                if (droppedOldest)
                    _items.Dequeue();
                _items.Enqueue(packet);
                return droppedOldest;
            }
        }

        internal bool TryDequeue(out AudioPipePacket packet)
        {
            lock (_gate)
            {
                if (_items.Count == 0)
                {
                    packet = null;
                    return false;
                }
                packet = _items.Dequeue();
                return true;
            }
        }

        internal int Clear()
        {
            lock (_gate)
            {
                int count = _items.Count;
                _items.Clear();
                return count;
            }
        }
    }

    public sealed class NamedPipeAudioBroadcaster : IDisposable
    {
        private const int ConnectionSetupTimeoutSeconds = 5;
        private readonly BoundedAudioPipeQueue _queue;
        private readonly AudioBlockEncoder _encoder = new AudioBlockEncoder();
        private readonly AutoResetEvent _packetAvailable = new AutoResetEvent(false);
        private readonly CancellationTokenSource _stop = new CancellationTokenSource();
        private readonly TaskCompletionSource<bool> _ready =
            new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        private Thread _worker;
        private float[] _normalizedScratch = new float[0];
        private NamedPipeServerStream _activePipe;
        private Exception _lastError;
        private int _started;
        private int _disposed;
        private int _connected;
        private long _droppedPackets;
        private long _unconnectedPackets;
        private long _transmittedPackets;
        private long _transmittedBytes;
        private long _clientDisconnects;

        public string PipeName { get; private set; }
        public string PipePath { get { return @"\\.\pipe\" + PipeName; } }
        public bool IsClientConnected { get { return Volatile.Read(ref _connected) != 0; } }
        public long DroppedPackets { get { return Interlocked.Read(ref _droppedPackets); } }
        public long UnconnectedPackets { get { return Interlocked.Read(ref _unconnectedPackets); } }
        public long TransmittedPackets { get { return Interlocked.Read(ref _transmittedPackets); } }
        public long TransmittedBytes { get { return Interlocked.Read(ref _transmittedBytes); } }
        public long ClientDisconnects { get { return Interlocked.Read(ref _clientDisconnects); } }
        public string LastError
        {
            get
            {
                Exception error = Volatile.Read(ref _lastError);
                return error == null ? null : error.GetType().Name + ": " + error.Message;
            }
        }

        public NamedPipeAudioBroadcaster(string pipeName, int queueCapacity)
        {
            if (String.IsNullOrWhiteSpace(pipeName))
                throw new ArgumentException("A pipe name is required.", "pipeName");
            if (pipeName.IndexOfAny(new char[] { '\\', '/' }) >= 0)
                throw new ArgumentException("Use a pipe name, not a path.", "pipeName");
            if (queueCapacity <= 0)
                throw new ArgumentOutOfRangeException("queueCapacity");

            PipeName = pipeName;
            _queue = new BoundedAudioPipeQueue(queueCapacity);
        }

        public void Start()
        {
            if (Interlocked.CompareExchange(ref _started, 1, 0) != 0)
                throw new InvalidOperationException("The named-pipe broadcaster can only be started once.");
            if (Volatile.Read(ref _disposed) != 0)
                throw new ObjectDisposedException("NamedPipeAudioBroadcaster");

            _worker = new Thread(WorkerMain)
            {
                IsBackground = true,
                Name = "DUNGU pipe " + PipeName,
                Priority = ThreadPriority.AboveNormal
            };
            _worker.SetApartmentState(ApartmentState.MTA);
            _worker.Start();

            Task ready = Task.WhenAny(
                _ready.Task,
                Task.Delay(TimeSpan.FromSeconds(ConnectionSetupTimeoutSeconds))).GetAwaiter().GetResult();
            if (!Object.ReferenceEquals(ready, _ready.Task))
            {
                Dispose();
                throw new TimeoutException("Timed out while creating the local audio pipe.");
            }
            _ready.Task.GetAwaiter().GetResult();
        }

        public bool TryPublish(byte[] rawAudio, AudioTimelineEntry timeline)
        {
            if (rawAudio == null)
                throw new ArgumentNullException("rawAudio");
            if (rawAudio.Length == 0)
                throw new ArgumentException("Audio pipe packets cannot be empty.", "rawAudio");
            AudioPipeProtocol.ValidatePayload(timeline, rawAudio.Length, AudioStorageMode.Raw);

            if (Volatile.Read(ref _disposed) != 0)
                return false;
            if (!IsClientConnected)
            {
                Interlocked.Increment(ref _unconnectedPackets);
                return false;
            }

            var packet = new AudioPipePacket(timeline, rawAudio);
            if (_queue.EnqueueDroppingOldest(packet))
                Interlocked.Increment(ref _droppedPackets);
            _packetAvailable.Set();
            return true;
        }

        public void Dispose()
        {
            if (Interlocked.Exchange(ref _disposed, 1) != 0)
                return;

            _stop.Cancel();
            _packetAvailable.Set();
            NamedPipeServerStream active = Interlocked.Exchange(ref _activePipe, null);
            if (active != null)
                active.Dispose();

            if (_worker != null && _worker != Thread.CurrentThread && !_worker.Join(5000))
                throw new TimeoutException("The named-pipe worker did not stop within five seconds.");

            _packetAvailable.Dispose();
            _stop.Dispose();
        }

        private void WorkerMain()
        {
            while (!_stop.IsCancellationRequested)
            {
                NamedPipeServerStream pipe = null;
                try
                {
                    pipe = NativeMethods.CreateLocalCurrentUserPipe(PipeName);
                    Interlocked.Exchange(ref _activePipe, pipe);
                    _ready.TrySetResult(true);
                    pipe.WaitForConnectionAsync(_stop.Token).GetAwaiter().GetResult();
                    if (_stop.IsCancellationRequested)
                        break;

                    Volatile.Write(ref _connected, 1);
                    while (pipe.IsConnected && !_stop.IsCancellationRequested)
                    {
                        AudioPipePacket packet;
                        if (!_queue.TryDequeue(out packet))
                        {
                            _packetAvailable.WaitOne(100);
                            continue;
                        }

                        AudioTimelineEntry wireTimeline;
                        EncodedAudioBlock encoded = EncodePacket(packet, out wireTimeline);
                        byte[] header = AudioPipeProtocol.CreateHeader(wireTimeline, encoded.Payload.Length);
                        try
                        {
                            pipe.WriteAsync(header, 0, header.Length, _stop.Token).GetAwaiter().GetResult();
                            pipe.WriteAsync(encoded.Payload, 0, encoded.Payload.Length, _stop.Token).GetAwaiter().GetResult();
                        }
                        catch (IOException) when (!_stop.IsCancellationRequested)
                        {
                            Interlocked.Increment(ref _droppedPackets);
                            throw;
                        }
                        Interlocked.Increment(ref _transmittedPackets);
                        Interlocked.Add(ref _transmittedBytes, encoded.Payload.Length);
                    }
                }
                catch (OperationCanceledException) when (_stop.IsCancellationRequested)
                {
                    break;
                }
                catch (IOException) when (!_stop.IsCancellationRequested)
                {
                    Interlocked.Increment(ref _clientDisconnects);
                    ClearPendingPackets();
                }
                catch (Exception error)
                {
                    if (!_stop.IsCancellationRequested)
                    {
                        Interlocked.CompareExchange(ref _lastError, error, null);
                        _ready.TrySetException(error);
                    }
                    break;
                }
                finally
                {
                    Volatile.Write(ref _connected, 0);
                    Interlocked.CompareExchange(ref _activePipe, null, pipe);
                    if (pipe != null)
                        pipe.Dispose();
                    ClearPendingPackets();
                }
            }
        }

        private void ClearPendingPackets()
        {
            int discardedCount = _queue.Clear();
            if (discardedCount > 0)
                Interlocked.Add(ref _droppedPackets, discardedCount);
        }

        private EncodedAudioBlock EncodePacket(AudioPipePacket packet, out AudioTimelineEntry wireTimeline)
        {
            AudioTimelineEntry sourceTimeline = packet.Timeline;
            AudioSampleFormat format = AudioSampleFormat.FromTimeline(sourceTimeline);
            int sampleCount = checked(sourceTimeline.FrameCount * sourceTimeline.Channels);
            if (_normalizedScratch.Length < sampleCount)
                _normalizedScratch = new float[sampleCount];
            format.ConvertToFloat(packet.Payload, sourceTimeline.FrameCount, _normalizedScratch, 0);

            EncodedAudioBlock encoded = _encoder.Encode(
                packet.Payload,
                packet.Payload.Length,
                _normalizedScratch,
                sampleCount);

            wireTimeline = sourceTimeline;
            wireTimeline.StorageMode = (byte)encoded.StorageMode;
            wireTimeline.CompandingApplied = encoded.CompandingApplied ? (byte)1 : (byte)0;
            if (encoded.StorageMode == AudioStorageMode.ZlibCompandedFloat32)
            {
                wireTimeline.FormatTag = NativeMethods.WaveFormatIeeeFloat;
                wireTimeline.BitsPerSample = sizeof(float) * 8;
                wireTimeline.ValidBitsPerSample = sizeof(float) * 8;
                wireTimeline.BlockAlign = checked((ushort)(wireTimeline.Channels * sizeof(float)));
            }
            return encoded;
        }
    }

    public sealed class AudioTimelineRingBuffer
    {
        public const int DefaultCapacityBytes = 268435456;
        public const int DefaultTimelineCapacity = 1048576;

        private readonly object _gate = new object();
        private readonly byte[] _payload;
        private readonly AudioTimelineEntry[] _timeline;
        private long _oldestSequence;
        private long _nextSequence;
        private long _oldestByteOffset;
        private long _nextByteOffset;
        private long _bufferedOriginalBytes;
        private long _totalOriginalBytes;
        private long _totalStoredBytes;

        public AudioTimelineRingBuffer()
            : this(DefaultCapacityBytes, DefaultTimelineCapacity)
        {
        }

        internal AudioTimelineRingBuffer(int capacityBytes, int timelineCapacity)
        {
            if (capacityBytes <= 0)
                throw new ArgumentOutOfRangeException("capacityBytes");
            if (timelineCapacity <= 0)
                throw new ArgumentOutOfRangeException("timelineCapacity");

            _payload = new byte[capacityBytes];
            _timeline = new AudioTimelineEntry[timelineCapacity];
        }

        public int CapacityBytes { get { return _payload.Length; } }
        public int TimelineCapacity { get { return _timeline.Length; } }

        public long OldestSequence
        {
            get { lock (_gate) return _oldestSequence; }
        }

        public long NextSequence
        {
            get { lock (_gate) return _nextSequence; }
        }

        public long BufferedStoredBytes
        {
            get { lock (_gate) return _nextByteOffset - _oldestByteOffset; }
        }

        public long BufferedOriginalBytes
        {
            get { lock (_gate) return _bufferedOriginalBytes; }
        }

        public long TotalOriginalBytes
        {
            get { lock (_gate) return _totalOriginalBytes; }
        }

        public long TotalStoredBytes
        {
            get { lock (_gate) return _totalStoredBytes; }
        }

        public double TotalSavingsPercent
        {
            get
            {
                lock (_gate)
                {
                    return _totalOriginalBytes == 0
                        ? 0
                        : 100.0 * (1.0 - ((double)_totalStoredBytes / _totalOriginalBytes));
                }
            }
        }

        public long Append(byte[] payload, int payloadLength, AudioTimelineEntry entry)
        {
            if (payload == null)
                throw new ArgumentNullException("payload");
            if (payloadLength <= 0 || payloadLength > payload.Length)
                throw new ArgumentOutOfRangeException("payloadLength");
            if (entry.OriginalByteLength <= 0 || entry.FrameCount <= 0 || entry.Channels <= 0)
                throw new ArgumentException("Timeline metadata must describe non-empty audio.", "entry");
            if (payloadLength > _payload.Length)
                throw new ArgumentOutOfRangeException("payloadLength", "A block cannot exceed the ring capacity.");

            lock (_gate)
            {
                MakeRoom(payloadLength);
                long sequence = _nextSequence;
                long absoluteOffset = _nextByteOffset;
                int ringOffset = (int)(absoluteOffset % _payload.Length);
                int firstCount = Math.Min(payloadLength, _payload.Length - ringOffset);
                Array.Copy(payload, 0, _payload, ringOffset, firstCount);
                if (firstCount < payloadLength)
                    Array.Copy(payload, firstCount, _payload, 0, payloadLength - firstCount);

                entry.Sequence = sequence;
                entry.AbsoluteByteOffset = absoluteOffset;
                entry.StoredByteLength = payloadLength;
                _timeline[(int)(sequence % _timeline.Length)] = entry;
                _nextSequence++;
                _nextByteOffset += payloadLength;
                _bufferedOriginalBytes += entry.OriginalByteLength;
                _totalOriginalBytes += entry.OriginalByteLength;
                _totalStoredBytes += payloadLength;
                return sequence;
            }
        }

        public AudioTimelineEntry[] GetTimelineSnapshot(long startSequence, int maxEntries)
        {
            if (maxEntries < 0)
                throw new ArgumentOutOfRangeException("maxEntries");
            if (maxEntries == 0)
                return new AudioTimelineEntry[0];

            lock (_gate)
            {
                long firstSequence = Math.Max(startSequence, _oldestSequence);
                if (firstSequence >= _nextSequence)
                    return new AudioTimelineEntry[0];

                long available = _nextSequence - firstSequence;
                int count = (int)Math.Min(available, maxEntries);
                var result = new AudioTimelineEntry[count];
                for (int index = 0; index < count; index++)
                {
                    long sequence = firstSequence + index;
                    AudioTimelineEntry entry = _timeline[(int)(sequence % _timeline.Length)];
                    if (entry.Sequence != sequence)
                        throw new InvalidOperationException("Timeline sequence mismatch.");
                    result[index] = entry;
                }
                return result;
            }
        }

        public bool TryReadPayload(long sequence, byte[] destination, int destinationOffset, out AudioTimelineEntry entry)
        {
            if (destination == null)
                throw new ArgumentNullException("destination");

            lock (_gate)
            {
                if (sequence < _oldestSequence || sequence >= _nextSequence)
                {
                    entry = default(AudioTimelineEntry);
                    return false;
                }

                entry = _timeline[(int)(sequence % _timeline.Length)];
                if (entry.Sequence != sequence
                    || entry.AbsoluteByteOffset < _oldestByteOffset
                    || entry.AbsoluteByteOffset + entry.StoredByteLength > _nextByteOffset)
                {
                    entry = default(AudioTimelineEntry);
                    return false;
                }
                if (destinationOffset < 0 || destinationOffset > destination.Length - entry.StoredByteLength)
                    throw new ArgumentOutOfRangeException("destinationOffset");

                int ringOffset = (int)(entry.AbsoluteByteOffset % _payload.Length);
                int firstCount = Math.Min(entry.StoredByteLength, _payload.Length - ringOffset);
                Array.Copy(_payload, ringOffset, destination, destinationOffset, firstCount);
                if (firstCount < entry.StoredByteLength)
                    Array.Copy(_payload, 0, destination, destinationOffset + firstCount, entry.StoredByteLength - firstCount);
                return true;
            }
        }

        private void MakeRoom(int incomingLength)
        {
            long desiredOldest = Math.Max(_oldestByteOffset, _nextByteOffset + incomingLength - _payload.Length);
            while (_oldestSequence < _nextSequence)
            {
                bool timelineFull = _nextSequence - _oldestSequence >= _timeline.Length;
                AudioTimelineEntry oldest = _timeline[(int)(_oldestSequence % _timeline.Length)];
                if (oldest.Sequence != _oldestSequence)
                    throw new InvalidOperationException("Timeline eviction sequence mismatch.");

                bool payloadExpired = oldest.AbsoluteByteOffset < desiredOldest;
                if (!timelineFull && !payloadExpired)
                    break;

                _oldestSequence++;
                _oldestByteOffset = Math.Max(
                    _oldestByteOffset,
                    oldest.AbsoluteByteOffset + oldest.StoredByteLength);
                _bufferedOriginalBytes -= oldest.OriginalByteLength;
                desiredOldest = Math.Max(desiredOldest, _oldestByteOffset);
            }

            _oldestByteOffset = Math.Max(_oldestByteOffset, desiredOldest);
        }
    }

    public static class ZlibCodec
    {
        public static byte[] Compress(byte[] input, int offset, int count)
        {
            if (input == null)
                throw new ArgumentNullException("input");
            if (offset < 0 || count < 0 || offset > input.Length - count)
                throw new ArgumentOutOfRangeException("offset");

            using (var output = new MemoryStream())
            {
                output.WriteByte(0x78);
                output.WriteByte(0x01);
                using (var deflater = new DeflateStream(output, CompressionLevel.Fastest, true))
                    deflater.Write(input, offset, count);

                uint checksum = Adler32(input, offset, count);
                output.WriteByte((byte)(checksum >> 24));
                output.WriteByte((byte)(checksum >> 16));
                output.WriteByte((byte)(checksum >> 8));
                output.WriteByte((byte)checksum);
                return output.ToArray();
            }
        }

        public static byte[] Decompress(byte[] input, int offset, int count, int expectedLength)
        {
            if (input == null)
                throw new ArgumentNullException("input");
            if (offset < 0 || count < 6 || offset > input.Length - count)
                throw new InvalidDataException("The ZLIB block is truncated.");
            if (expectedLength < 0)
                throw new ArgumentOutOfRangeException("expectedLength");

            int cmf = input[offset];
            int flg = input[offset + 1];
            if ((cmf & 0x0F) != 8 || (cmf >> 4) > 7 || (((cmf << 8) | flg) % 31) != 0 || (flg & 0x20) != 0)
                throw new InvalidDataException("The ZLIB header is invalid or requests a preset dictionary.");

            uint expectedChecksum =
                ((uint)input[offset + count - 4] << 24)
                | ((uint)input[offset + count - 3] << 16)
                | ((uint)input[offset + count - 2] << 8)
                | input[offset + count - 1];

            using (var deflateInput = new MemoryStream(input, offset + 2, count - 6, false))
            using (var inflater = new DeflateStream(deflateInput, CompressionMode.Decompress))
            using (var output = new MemoryStream(expectedLength))
            {
                byte[] scratch = new byte[8192];
                int read;
                while ((read = inflater.Read(scratch, 0, scratch.Length)) != 0)
                {
                    if (output.Length > expectedLength - read)
                        throw new InvalidDataException("The ZLIB block expands beyond its declared size.");
                    output.Write(scratch, 0, read);
                }

                byte[] result = output.ToArray();
                if (result.Length != expectedLength)
                    throw new InvalidDataException("The ZLIB block does not match its declared size.");
                if (Adler32(result, 0, result.Length) != expectedChecksum)
                    throw new InvalidDataException("The ZLIB Adler-32 checksum does not match.");
                return result;
            }
        }

        private static uint Adler32(byte[] data, int offset, int count)
        {
            const uint Modulus = 65521;
            uint first = 1;
            uint second = 0;
            int end = offset + count;
            for (int index = offset; index < end; index++)
            {
                first = (first + data[index]) % Modulus;
                second = (second + first) % Modulus;
            }
            return (second << 16) | first;
        }
    }

    internal sealed class FourDCompander
    {
        private const float FsiThreshold = 0.65f;
        private const float ReleaseThreshold = FsiThreshold * 0.3f;
        internal const float MaximumRoundTripError = 0.00001f;
        private int _padlocked;

        internal bool TryApply(float[] source, int sampleCount, float[] destination, out float maximumError)
        {
            if (source == null)
                throw new ArgumentNullException("source");
            if (destination == null)
                throw new ArgumentNullException("destination");
            if (sampleCount < 0 || sampleCount > source.Length || sampleCount > destination.Length)
                throw new ArgumentOutOfRangeException("sampleCount");

            maximumError = 0;
            if (sampleCount == 0)
                return false;

            int vectorSize = Vector<float>.Count;
            int index = 0;
            float absoluteSum = 0;
            for (; index <= sampleCount - vectorSize; index += vectorSize)
            {
                Vector<float> values = new Vector<float>(source, index);
                absoluteSum += Vector.Dot(Vector.Abs(values), Vector<float>.One);
            }
            for (; index < sampleCount; index++)
                absoluteSum += Math.Abs(source[index]);

            float meanAbsoluteAmplitude = absoluteSum / sampleCount;
            if (meanAbsoluteAmplitude > FsiThreshold)
                _padlocked = 1;
            else if (meanAbsoluteAmplitude < ReleaseThreshold)
                _padlocked = 0;

            if (_padlocked == 0)
                return false;

            index = 0;
            Vector<float> negativeOne = new Vector<float>(-1.0f);
            for (; index <= sampleCount - vectorSize; index += vectorSize)
            {
                Vector<float> values = new Vector<float>(source, index);
                Vector<float> sign = Vector.ConditionalSelect(
                    Vector.GreaterThanOrEqual(values, Vector<float>.Zero),
                    Vector<float>.One,
                    negativeOne);
                (sign * Vector.SquareRoot(Vector.Abs(values))).CopyTo(destination, index);
            }
            for (; index < sampleCount; index++)
                destination[index] = (source[index] < 0 ? -1.0f : 1.0f) * (float)Math.Sqrt(Math.Abs(source[index]));

            for (int sample = 0; sample < sampleCount; sample++)
            {
                float expanded = Expand(destination[sample]);
                float error = Math.Abs(expanded - source[sample]);
                if (Single.IsNaN(error) || Single.IsInfinity(error))
                {
                    maximumError = Single.PositiveInfinity;
                    return true;
                }
                if (error > maximumError)
                    maximumError = error;
            }
            return true;
        }

        internal static float Expand(float value)
        {
            return (value < 0 ? -1.0f : 1.0f) * value * value;
        }
    }

    internal sealed class EncodedAudioBlock
    {
        internal byte[] Payload;
        internal AudioStorageMode StorageMode;
        internal bool CompandingApplied;
    }

    internal sealed class AudioBlockEncoder
    {
        private readonly FourDCompander _compander = new FourDCompander();
        private float[] _compandedSamples = new float[0];

        internal EncodedAudioBlock Encode(byte[] rawBytes, int rawByteCount, float[] normalizedSamples, int sampleCount)
        {
            if (rawBytes == null)
                throw new ArgumentNullException("rawBytes");
            if (rawByteCount <= 0 || rawByteCount > rawBytes.Length)
                throw new ArgumentOutOfRangeException("rawByteCount");

            byte[] bestPayload = rawBytes;
            AudioStorageMode bestMode = AudioStorageMode.Raw;
            byte[] compressedRaw = ZlibCodec.Compress(rawBytes, 0, rawByteCount);
            if (compressedRaw.Length < rawByteCount)
            {
                bestPayload = compressedRaw;
                bestMode = AudioStorageMode.ZlibRaw;
            }

            if (sampleCount > 0)
            {
                if (_compandedSamples.Length < sampleCount)
                    _compandedSamples = new float[sampleCount];

                float maximumError;
                bool companded = _compander.TryApply(
                    normalizedSamples,
                    sampleCount,
                    _compandedSamples,
                    out maximumError);
                if (companded && maximumError <= FourDCompander.MaximumRoundTripError)
                {
                    byte[] compandedBytes = new byte[checked(sampleCount * sizeof(float))];
                    Buffer.BlockCopy(_compandedSamples, 0, compandedBytes, 0, compandedBytes.Length);
                    byte[] compressedCompanded = ZlibCodec.Compress(compandedBytes, 0, compandedBytes.Length);
                    if (compressedCompanded.Length < bestPayload.Length)
                    {
                        bestPayload = compressedCompanded;
                        bestMode = AudioStorageMode.ZlibCompandedFloat32;
                    }
                }
            }

            return new EncodedAudioBlock
            {
                Payload = bestPayload,
                StorageMode = bestMode,
                CompandingApplied = bestMode == AudioStorageMode.ZlibCompandedFloat32
            };
        }
    }

    public sealed class SignalProcessorPass
    {
        public long PassNumber { get; internal set; }
        public int SegmentsProcessed { get; internal set; }
        public int SegmentsExpired { get; internal set; }
        public long SamplesProcessed { get; internal set; }
        public long FirstSequence { get; internal set; }
        public long LastSequence { get; internal set; }
        public float Peak { get; internal set; }
    }

    public sealed class SignalProcessor
    {
        private const int BatchSize = 4096;
        private readonly AudioTimelineRingBuffer _ring;
        private long _passNumber;

        public SignalProcessor(AudioTimelineRingBuffer ring)
        {
            _ring = ring ?? throw new ArgumentNullException("ring");
        }

        public SignalProcessorPass ProcessPass(long startSequence, int maxSegments)
        {
            if (maxSegments <= 0)
                throw new ArgumentOutOfRangeException("maxSegments");

            var result = new SignalProcessorPass
            {
                PassNumber = Interlocked.Increment(ref _passNumber),
                FirstSequence = -1,
                LastSequence = -1
            };
            long cursor = startSequence;
            int remaining = maxSegments;
            byte[] payload = new byte[0];

            while (remaining > 0)
            {
                int requested = Math.Min(remaining, BatchSize);
                AudioTimelineEntry[] entries = _ring.GetTimelineSnapshot(cursor, requested);
                if (entries.Length == 0)
                    break;

                foreach (AudioTimelineEntry entry in entries)
                {
                    cursor = entry.Sequence + 1;
                    if (entry.StoredByteLength > payload.Length)
                        Array.Resize(ref payload, entry.StoredByteLength);
                    AudioTimelineEntry current;
                    if (!_ring.TryReadPayload(entry.Sequence, payload, 0, out current))
                    {
                        result.SegmentsExpired++;
                        continue;
                    }

                    float peak = MeasureBlock(payload, current);
                    if (peak > result.Peak)
                        result.Peak = peak;
                    if (result.FirstSequence < 0)
                        result.FirstSequence = current.Sequence;
                    result.LastSequence = current.Sequence;
                    result.SegmentsProcessed++;
                    result.SamplesProcessed += (long)current.FrameCount * current.Channels;
                }

                remaining -= entries.Length;
            }

            return result;
        }

        private static float MeasureBlock(byte[] payload, AudioTimelineEntry entry)
        {
            // For a silent WASAPI packet, the sample bytes are undefined. Capture stores
            // zeroed bytes for bounded memory handling; honor the flag instead of decoding
            // those bytes as PCM (notably, zero is full-scale negative for unsigned PCM8).
            if ((entry.Flags & NativeMethods.AudioClientBufferFlagSilent) != 0)
                return 0;

            AudioStorageMode mode = (AudioStorageMode)entry.StorageMode;
            if (mode == AudioStorageMode.Raw)
                return AudioSampleFormat.FromTimeline(entry).MeasurePeak(payload, 0, entry.FrameCount);

            if (mode == AudioStorageMode.ZlibRaw)
            {
                byte[] raw = ZlibCodec.Decompress(payload, 0, entry.StoredByteLength, entry.OriginalByteLength);
                return AudioSampleFormat.FromTimeline(entry).MeasurePeak(raw, 0, entry.FrameCount);
            }

            if (mode == AudioStorageMode.ZlibCompandedFloat32)
            {
                int sampleCount = checked(entry.FrameCount * entry.Channels);
                byte[] decoded = ZlibCodec.Decompress(
                    payload,
                    0,
                    entry.StoredByteLength,
                    checked(sampleCount * sizeof(float)));
                float peak = 0;
                for (int index = 0; index < sampleCount; index++)
                {
                    float value = BitConverter.ToSingle(decoded, index * sizeof(float));
                    if (entry.CompandingApplied != 0)
                        value = FourDCompander.Expand(value);
                    if (!Single.IsNaN(value) && !Single.IsInfinity(value))
                        peak = Math.Max(peak, Math.Abs(value));
                }
                return peak;
            }

            throw new InvalidDataException("The timeline entry has an unknown storage mode.");
        }
    }

    public sealed class NativeProcessLoopbackServer : IDisposable
    {
        private const int SharedMode = 0;
        private const int BufferDurationHns = 1000000;
        private const int ActivationTimeoutSeconds = 30;

        private readonly bool _includeProcessTree;
        private readonly AudioTimelineRingBuffer _ring;
        private readonly NamedPipeAudioBroadcaster _pipe;
        private readonly AudioBlockEncoder _encoder = new AudioBlockEncoder();
        private readonly ManualResetEventSlim _stopRequested = new ManualResetEventSlim(false);
        private readonly TaskCompletionSource<bool> _startup =
            new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);

        private Thread _captureThread;
        private float[] _normalizedScratch = new float[0];
        private Exception _lastError;
        private int _startState;
        private int _disposed;
        private int _running;
        private int _peakBits;
        private long _pipeSequence;

        public uint ProcessId { get; private set; }
        public string ProcessName { get; private set; }
        public bool IsRunning { get { return Volatile.Read(ref _running) != 0; } }
        public string PipePath { get { return _pipe == null ? null : _pipe.PipePath; } }
        public bool IsPipeClientConnected { get { return _pipe != null && _pipe.IsClientConnected; } }
        public long PipeDroppedPackets { get { return _pipe == null ? 0 : _pipe.DroppedPackets; } }
        public long PipeUnconnectedPackets { get { return _pipe == null ? 0 : _pipe.UnconnectedPackets; } }
        public long PipeTransmittedPackets { get { return _pipe == null ? 0 : _pipe.TransmittedPackets; } }
        public long PipeTransmittedBytes { get { return _pipe == null ? 0 : _pipe.TransmittedBytes; } }
        public long PipeClientDisconnects { get { return _pipe == null ? 0 : _pipe.ClientDisconnects; } }
        public string LastError
        {
            get
            {
                Exception error = Volatile.Read(ref _lastError);
                if (error != null)
                    return error.GetType().Name + ": " + error.Message;
                return _pipe == null ? null : _pipe.LastError;
            }
        }

        public NativeProcessLoopbackServer(
            uint targetProcessId,
            string processName,
            bool includeProcessTree,
            AudioTimelineRingBuffer ring,
            bool enablePipe,
            int pipeQueuePackets)
        {
            if (targetProcessId == 0)
                throw new ArgumentOutOfRangeException("targetProcessId");
            if (String.IsNullOrWhiteSpace(processName))
                throw new ArgumentException("A process name is required.", "processName");
            if (ring == null)
                throw new ArgumentNullException("ring");

            ProcessId = targetProcessId;
            ProcessName = processName;
            _includeProcessTree = includeProcessTree;
            _ring = ring;
            if (enablePipe)
                _pipe = new NamedPipeAudioBroadcaster("DunguAudioPipe_" + targetProcessId, pipeQueuePackets);
        }

        public void Start()
        {
            if (Volatile.Read(ref _disposed) != 0)
                throw new ObjectDisposedException("NativeProcessLoopbackServer");
            if (Interlocked.CompareExchange(ref _startState, 1, 0) != 0)
                throw new InvalidOperationException("The loopback server can only be started once.");

            try
            {
                _captureThread = new Thread(CaptureThreadMain);
                _captureThread.IsBackground = true;
                _captureThread.Name = "DUNGU loopback PID " + ProcessId;
                _captureThread.SetApartmentState(ApartmentState.MTA);
                _captureThread.Start();

                Task completed = Task.WhenAny(
                    _startup.Task,
                    Task.Delay(TimeSpan.FromSeconds(ActivationTimeoutSeconds + 5))).GetAwaiter().GetResult();
                if (!Object.ReferenceEquals(completed, _startup.Task))
                    throw new TimeoutException("Timed out waiting for the process loopback audio client to initialize.");

                _startup.Task.GetAwaiter().GetResult();
            }
            catch
            {
                _stopRequested.Set();
                if (_captureThread != null && _captureThread.IsAlive)
                    _captureThread.Join();
                throw;
            }
        }

        public float ConsumePeak()
        {
            int peakBits = Interlocked.Exchange(ref _peakBits, 0);
            return BitConverter.Int32BitsToSingle(peakBits);
        }

        private void CaptureThreadMain()
        {
            IAudioClient audioClient = null;
            IAudioCaptureClient captureClient = null;
            AudioSampleFormat sampleFormat = null;
            bool started = false;

            try
            {
                audioClient = ActivateAudioClient();

                sampleFormat = AudioSampleFormat.CreateProcessLoopbackCaptureFormat();
                WaveFormatEx captureFormat = new WaveFormatEx
                {
                    FormatTag = (ushort)NativeMethods.WaveFormatPcm,
                    Channels = 2,
                    SamplesPerSecond = 44100,
                    AverageBytesPerSecond = 44100 * 4,
                    BlockAlign = 4,
                    BitsPerSample = 16,
                    ExtraSize = 0
                };
                IntPtr formatPointer = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(WaveFormatEx)));
                try
                {
                    Marshal.StructureToPtr(captureFormat, formatPointer, false);
                    NativeMethods.ThrowIfFailed(
                        audioClient.Initialize(
                            SharedMode,
                            NativeMethods.AudioClientStreamFlagsLoopback
                                | NativeMethods.AudioClientStreamFlagsAutoConvertPcm,
                            BufferDurationHns,
                            0,
                            formatPointer,
                            IntPtr.Zero),
                        "IAudioClient.Initialize");
                }
                finally
                {
                    Marshal.FreeHGlobal(formatPointer);
                }

                object captureObject;
                Guid captureClientId = NativeMethods.AudioCaptureClientInterfaceId;
                NativeMethods.ThrowIfFailed(
                    audioClient.GetService(ref captureClientId, out captureObject),
                    "IAudioClient.GetService(IAudioCaptureClient)");
                captureClient = captureObject as IAudioCaptureClient;
                if (captureClient == null)
                    throw new InvalidCastException("IAudioClient.GetService did not return IAudioCaptureClient.");

                if (_pipe != null)
                    _pipe.Start();

                NativeMethods.ThrowIfFailed(audioClient.Start(), "IAudioClient.Start");
                started = true;
                Volatile.Write(ref _running, 1);
                _startup.TrySetResult(true);

                CaptureLoop(captureClient, sampleFormat);
            }
            catch (Exception error)
            {
                if (started)
                    RecordError(error);
                else
                    _startup.TrySetException(error);
            }
            finally
            {
                Volatile.Write(ref _running, 0);

                if (started && audioClient != null)
                {
                    try
                    {
                        NativeMethods.ThrowIfFailed(audioClient.Stop(), "IAudioClient.Stop");
                    }
                    catch (Exception error)
                    {
                        RecordError(error);
                    }
                }

                ReleaseComObject(captureClient);
                ReleaseComObject(audioClient);
                if (_pipe != null)
                {
                    try
                    {
                        _pipe.Dispose();
                    }
                    catch (Exception error)
                    {
                        RecordError(error);
                    }
                }
            }
        }

        private void CaptureLoop(IAudioCaptureClient captureClient, AudioSampleFormat sampleFormat)
        {
            while (!_stopRequested.IsSet)
            {
                int packetFrames;
                NativeMethods.ThrowIfFailed(
                    captureClient.GetNextPacketSize(out packetFrames),
                    "IAudioCaptureClient.GetNextPacketSize");

                while (packetFrames > 0 && !_stopRequested.IsSet)
                {
                    IntPtr data;
                    int frames;
                    int flags;
                    long devicePosition;
                    long qpcPosition;
                    NativeMethods.ThrowIfFailed(
                        captureClient.GetBuffer(out data, out frames, out flags, out devicePosition, out qpcPosition),
                        "IAudioCaptureClient.GetBuffer");

                    int originalByteLength = checked(frames * sampleFormat.BlockAlign);
                    int sampleCount = checked(frames * sampleFormat.Channels);
                    byte[] rawBytes = new byte[originalByteLength];
                    if (_normalizedScratch.Length < sampleCount)
                        _normalizedScratch = new float[sampleCount];
                    float peak;
                    try
                    {
                        if ((flags & NativeMethods.AudioClientBufferFlagSilent) == 0)
                        {
                            Marshal.Copy(data, rawBytes, 0, originalByteLength);
                            sampleFormat.ConvertToFloat(data, frames, _normalizedScratch, 0);
                        }
                        else
                        {
                            Array.Clear(rawBytes, 0, rawBytes.Length);
                            Array.Clear(_normalizedScratch, 0, sampleCount);
                        }
                        peak = sampleFormat.MeasurePeak(_normalizedScratch, sampleCount);
                    }
                    finally
                    {
                        NativeMethods.ThrowIfFailed(captureClient.ReleaseBuffer(frames), "IAudioCaptureClient.ReleaseBuffer");
                    }

                    AudioTimelineEntry timeline = new AudioTimelineEntry
                    {
                        Sequence = Interlocked.Increment(ref _pipeSequence) - 1,
                        QpcPosition = qpcPosition,
                        DevicePosition = devicePosition,
                        ProcessId = checked((int)ProcessId),
                        OriginalByteLength = originalByteLength,
                        FrameCount = frames,
                        Flags = flags,
                        SampleRate = sampleFormat.SampleRate,
                        Channels = checked((ushort)sampleFormat.Channels),
                        BlockAlign = checked((ushort)sampleFormat.BlockAlign),
                        FormatTag = checked((ushort)sampleFormat.Encoding),
                        BitsPerSample = checked((byte)sampleFormat.ContainerBits),
                        ValidBitsPerSample = checked((byte)sampleFormat.ValidBits)
                    };
                    if (_pipe != null)
                        _pipe.TryPublish(rawBytes, timeline);

                    EncodedAudioBlock encoded = _encoder.Encode(rawBytes, originalByteLength, _normalizedScratch, sampleCount);
                    timeline.StorageMode = (byte)encoded.StorageMode;
                    timeline.CompandingApplied = encoded.CompandingApplied ? (byte)1 : (byte)0;
                    _ring.Append(encoded.Payload, encoded.Payload.Length, timeline);
                    PublishPeak(peak);
                    NativeMethods.ThrowIfFailed(
                        captureClient.GetNextPacketSize(out packetFrames),
                        "IAudioCaptureClient.GetNextPacketSize");
                }

                if (packetFrames == 0)
                    _stopRequested.Wait(5);
            }
        }

        private IAudioClient ActivateAudioClient()
        {
            IntPtr propVariant = IntPtr.Zero;
            IntPtr activationData = IntPtr.Zero;
            IActivateAudioInterfaceAsyncOperation activationOperation = null;
            ActivationHandler handler = new ActivationHandler();
            bool cleanupDeferred = false;

            try
            {
                propVariant = NativeMethods.CreateActivationPropVariant(
                    ProcessId,
                    _includeProcessTree,
                    out activationData);

                int hr = NativeMethods.ActivateAudioInterfaceAsync(
                    "VAD\\Process_Loopback",
                    NativeMethods.AudioClientInterfaceId,
                    propVariant,
                    handler,
                    out activationOperation);
                NativeMethods.ThrowIfFailed(hr, "ActivateAudioInterfaceAsync");

                Task completed = Task.WhenAny(
                    handler.Completion,
                    Task.Delay(TimeSpan.FromSeconds(ActivationTimeoutSeconds))).GetAwaiter().GetResult();
                if (!Object.ReferenceEquals(completed, handler.Completion))
                {
                    IntPtr deferredPropVariant = propVariant;
                    IntPtr deferredActivationData = activationData;
                    IActivateAudioInterfaceAsyncOperation deferredOperation = activationOperation;
                    cleanupDeferred = true;
                    handler.Completion.ContinueWith(
                        ignored =>
                        {
                            ReleaseComObject(deferredOperation);
                            if (deferredPropVariant != IntPtr.Zero)
                                Marshal.FreeHGlobal(deferredPropVariant);
                            if (deferredActivationData != IntPtr.Zero)
                                Marshal.FreeHGlobal(deferredActivationData);
                        },
                        CancellationToken.None,
                        TaskContinuationOptions.ExecuteSynchronously,
                        TaskScheduler.Default);
                    propVariant = IntPtr.Zero;
                    activationData = IntPtr.Zero;
                    activationOperation = null;
                    throw new TimeoutException("Timed out waiting for process loopback activation.");
                }

                return handler.Completion.GetAwaiter().GetResult();
            }
            finally
            {
                if (!cleanupDeferred)
                {
                    ReleaseComObject(activationOperation);
                    if (propVariant != IntPtr.Zero)
                        Marshal.FreeHGlobal(propVariant);
                    if (activationData != IntPtr.Zero)
                        Marshal.FreeHGlobal(activationData);
                }
            }
        }

        private void PublishPeak(float peak)
        {
            if (Single.IsNaN(peak) || Single.IsInfinity(peak) || peak <= 0)
                return;

            int candidateBits = BitConverter.SingleToInt32Bits(peak);
            while (true)
            {
                int currentBits = Volatile.Read(ref _peakBits);
                float currentPeak = BitConverter.Int32BitsToSingle(currentBits);
                if (currentPeak >= peak)
                    return;
                if (Interlocked.CompareExchange(ref _peakBits, candidateBits, currentBits) == currentBits)
                    return;
            }
        }

        private void RecordError(Exception error)
        {
            Interlocked.CompareExchange(ref _lastError, error, null);
        }

        private void ReleaseComObject(object instance)
        {
            if (instance == null || !Marshal.IsComObject(instance))
                return;

            try
            {
                Marshal.ReleaseComObject(instance);
            }
            catch (Exception error)
            {
                RecordError(error);
            }
        }

        public void Dispose()
        {
            if (Interlocked.Exchange(ref _disposed, 1) != 0)
                return;

            try
            {
                _stopRequested.Set();
                if (_captureThread != null && _captureThread != Thread.CurrentThread)
                    _captureThread.Join();
            }
            finally
            {
                _stopRequested.Dispose();
            }
        }
    }

    public static class NativeProcessLoopbackDiagnostics
    {
        public static string[] RunSelfTests()
        {
            var passed = new List<string>();
            VerifyActivationLayout();
            passed.Add("inline process-loopback activation and PROPVARIANT layout");
            VerifyInterfaceIds();
            passed.Add("activation, audio-client, and agile callback interface IDs");
            VerifySampleDecoding();
            passed.Add("PCM 8/16/24/32-bit and IEEE float 32/64-bit peak decoding");
            VerifyExtensibleFormat();
            passed.Add("WAVEFORMATEXTENSIBLE valid-bits parsing");
            VerifyZlib();
            passed.Add("ZLIB framing, DEFLATE payload, and Adler-32 validation");
            VerifyAdaptiveEncoding();
            passed.Add("companding/ZLIB selection with a raw fallback that never expands blocks");
            VerifyPipeCompandedHeader();
            passed.Add("companded float32 pipe-frame metadata and bounded compressed payload");
            VerifyCompanding();
            passed.Add("4-D hysteresis companding and bounded inverse error");
            VerifyTimelineReplay();
            VerifyCompressedTimelineReplay();
            passed.Add("compressed timeline wraparound and repeatable signal passes");
            VerifyBoundedPipeQueue();
            passed.Add("nonblocking bounded pipe queue drops oldest stale packets");
            VerifyNamedPipeStreaming();
            passed.Add("same-user named-pipe connection and framed raw-audio delivery");
            return passed.ToArray();
        }

        private static void VerifyActivationLayout()
        {
            if (Marshal.SizeOf(typeof(AudioClientProcessLoopbackParams)) != 8)
                throw new InvalidOperationException("AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS must be 8 bytes.");
            if (Marshal.SizeOf(typeof(AudioClientActivationParams)) != 12)
                throw new InvalidOperationException("AUDIOCLIENT_ACTIVATION_PARAMS must be 12 bytes.");
            if (Marshal.OffsetOf(typeof(AudioClientActivationParams), "ProcessLoopbackParams").ToInt32() != 4)
                throw new InvalidOperationException("Process loopback parameters must be inline at offset 4.");

            IntPtr activationData;
            IntPtr propVariant = NativeMethods.CreateActivationPropVariant(1234, true, out activationData);
            try
            {
                int pointerOffset = IntPtr.Size == 8 ? 16 : 12;
                if (Marshal.ReadInt16(propVariant, 0) != 65)
                    throw new InvalidOperationException("The activation PROPVARIANT is not VT_BLOB.");
                if (Marshal.ReadInt32(propVariant, 8) != 12)
                    throw new InvalidOperationException("The activation blob length is incorrect.");
                if (Marshal.ReadIntPtr(propVariant, pointerOffset) != activationData)
                    throw new InvalidOperationException("The activation blob pointer is incorrect.");

                AudioClientActivationParams parameters =
                    (AudioClientActivationParams)Marshal.PtrToStructure(activationData, typeof(AudioClientActivationParams));
                if (parameters.ActivationType != NativeMethods.ProcessLoopbackActivationType
                    || parameters.ProcessLoopbackParams.TargetProcessId != 1234
                    || parameters.ProcessLoopbackParams.ProcessLoopbackMode != NativeMethods.IncludeTargetProcessTree)
                    throw new InvalidOperationException("The inline process-loopback activation payload is incorrect.");

                if (NativeMethods.PropVariantSize != (IntPtr.Size == 8 ? 24 : 16))
                    throw new InvalidOperationException("The PROPVARIANT size does not match the current architecture.");
            }
            finally
            {
                Marshal.FreeHGlobal(propVariant);
                Marshal.FreeHGlobal(activationData);
            }
        }

        private static void VerifyInterfaceIds()
        {
            AssertGuid(typeof(IActivateAudioInterfaceAsyncOperation), "72A22D78-CDE4-431D-B8CC-843A71199B6D");
            AssertGuid(typeof(IActivateAudioInterfaceCompletionHandler), "41D949AB-9862-444A-80F6-C261334DA5EB");
            AssertGuid(typeof(IAudioClient), "1CB9AD4C-DBFA-4C32-B178-C2F568A703B2");
            AssertGuid(typeof(IAudioCaptureClient), "C8ADBD64-E71E-48A0-A4DE-185C395CD317");
            AssertGuid(typeof(IAgileObject), "94EA2B94-E9CC-49E0-C0FF-EE64CA8F5B90");

            if (Marshal.SizeOf(typeof(WaveFormatEx)) != 18)
                throw new InvalidOperationException("WAVEFORMATEX must be 18 bytes.");
            if (Marshal.SizeOf(typeof(WaveFormatExtensible)) != 40)
                throw new InvalidOperationException("WAVEFORMATEXTENSIBLE must be 40 bytes.");
            if (Marshal.SizeOf(typeof(AudioTimelineEntry)) != 68)
                throw new InvalidOperationException("The packed audio timeline entry must be 68 bytes.");
            if (!typeof(IAgileObject).IsAssignableFrom(typeof(ActivationHandler)))
                throw new InvalidOperationException("The activation completion handler must be agile.");
        }

        private static void VerifySampleDecoding()
        {
            IntPtr data = Marshal.AllocHGlobal(8);
            try
            {
                AudioSampleFormat pcm8 = AudioSampleFormat.CreateForTesting(NativeMethods.WaveFormatPcm, 1, 8, 8, 1);
                Marshal.WriteByte(data, 0, 255);
                Marshal.WriteByte(data, 1, 0);
                AssertPeak(pcm8.MeasurePeak(data, 2), 1.0f, "PCM8");

                AudioSampleFormat pcm16 = AudioSampleFormat.CreateForTesting(NativeMethods.WaveFormatPcm, 1, 16, 16, 2);
                Marshal.WriteInt16(data, 0, 16384);
                Marshal.WriteInt16(data, 2, -16384);
                AssertPeak(pcm16.MeasurePeak(data, 2), 0.5f, "PCM16");

                AudioSampleFormat pcm24 = AudioSampleFormat.CreateForTesting(NativeMethods.WaveFormatPcm, 1, 24, 24, 3);
                Write24(data, 0, 0x400000);
                Write24(data, 3, 0xC00000);
                AssertPeak(pcm24.MeasurePeak(data, 2), 0.5f, "PCM24");

                AudioSampleFormat pcm24In32 = AudioSampleFormat.CreateForTesting(NativeMethods.WaveFormatPcm, 1, 32, 24, 4);
                Marshal.WriteInt32(data, 0, 0x40000000);
                AssertPeak(pcm24In32.MeasurePeak(data, 1), 0.5f, "PCM24-in-32");

                AudioSampleFormat pcm32 = AudioSampleFormat.CreateForTesting(NativeMethods.WaveFormatPcm, 1, 32, 32, 4);
                Marshal.WriteInt32(data, 0, 0x40000000);
                Marshal.WriteInt32(data, 4, unchecked((int)0xC0000000));
                AssertPeak(pcm32.MeasurePeak(data, 2), 0.5f, "PCM32");

                AudioSampleFormat float32 = AudioSampleFormat.CreateForTesting(NativeMethods.WaveFormatIeeeFloat, 1, 32, 32, 4);
                Marshal.WriteInt32(data, 0, BitConverter.SingleToInt32Bits(-0.75f));
                AssertPeak(float32.MeasurePeak(data, 1), 0.75f, "IEEE float32");

                AudioSampleFormat float64 = AudioSampleFormat.CreateForTesting(NativeMethods.WaveFormatIeeeFloat, 1, 64, 64, 8);
                Marshal.WriteInt64(data, 0, BitConverter.DoubleToInt64Bits(0.625));
                AssertPeak(float64.MeasurePeak(data, 1), 0.625f, "IEEE float64");
            }
            finally
            {
                Marshal.FreeHGlobal(data);
            }
        }

        private static void VerifyExtensibleFormat()
        {
            IntPtr formatPointer = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(WaveFormatExtensible)));
            IntPtr data = Marshal.AllocHGlobal(4);
            try
            {
                WaveFormatExtensible format = new WaveFormatExtensible
                {
                    Format = new WaveFormatEx
                    {
                        FormatTag = NativeMethods.WaveFormatExtensible,
                        Channels = 1,
                        SamplesPerSecond = 48000,
                        AverageBytesPerSecond = 192000,
                        BlockAlign = 4,
                        BitsPerSample = 32,
                        ExtraSize = 22
                    },
                    ValidBitsPerSample = 24,
                    ChannelMask = 0,
                    SubFormat = NativeMethods.PcmSubFormat
                };
                Marshal.StructureToPtr(format, formatPointer, false);
                AudioSampleFormat parsed = AudioSampleFormat.FromNative(formatPointer);
                Marshal.WriteInt32(data, 0, 0x40000000);
                AssertPeak(parsed.MeasurePeak(data, 1), 0.5f, "WAVEFORMATEXTENSIBLE PCM");
            }
            finally
            {
                Marshal.FreeHGlobal(data);
                Marshal.FreeHGlobal(formatPointer);
            }
        }

        private static void VerifyZlib()
        {
            byte[] input = new byte[1024];
            for (int index = 0; index < input.Length; index++)
                input[index] = (byte)(index % 13);

            byte[] compressed = ZlibCodec.Compress(input, 0, input.Length);
            if (compressed.Length < 6 || compressed[0] != 0x78
                || ((((int)compressed[0] << 8) | compressed[1]) % 31) != 0)
                throw new InvalidOperationException("The compressor did not produce a valid ZLIB header.");

            byte[] expanded = ZlibCodec.Decompress(compressed, 0, compressed.Length, input.Length);
            if (expanded.Length != input.Length)
                throw new InvalidOperationException("The ZLIB round trip returned the wrong length.");
            for (int index = 0; index < input.Length; index++)
            {
                if (expanded[index] != input[index])
                    throw new InvalidOperationException("The ZLIB round trip changed input bytes.");
            }

            compressed[compressed.Length - 1] ^= 0x01;
            bool checksumRejected = false;
            try
            {
                ZlibCodec.Decompress(compressed, 0, compressed.Length, input.Length);
            }
            catch (InvalidDataException)
            {
                checksumRejected = true;
            }
            if (!checksumRejected)
                throw new InvalidOperationException("The ZLIB decoder did not reject a damaged Adler-32 checksum.");
        }

        private static void VerifyCompanding()
        {
            var compander = new FourDCompander();
            float[] source = new float[] { 0.81f, -0.81f, 0.9f, -0.9f };
            float[] encoded = new float[source.Length];
            float maximumError;
            if (!compander.TryApply(source, source.Length, encoded, out maximumError))
                throw new InvalidOperationException("The compander did not engage above its FSI threshold.");
            if (maximumError > FourDCompander.MaximumRoundTripError)
                throw new InvalidOperationException("The compander exceeded its configured round-trip error.");

            float[] quiet = new float[] { 0.1f, -0.1f, 0.05f, -0.05f };
            if (compander.TryApply(quiet, quiet.Length, encoded, out maximumError))
                throw new InvalidOperationException("The compander did not release below its PDI threshold.");
        }

        private static void VerifyAdaptiveEncoding()
        {
            var encoder = new AudioBlockEncoder();
            byte[] silence = new byte[256];
            float[] silentSamples = new float[128];
            EncodedAudioBlock silentBlock = encoder.Encode(silence, silence.Length, silentSamples, silentSamples.Length);
            if (silentBlock.StorageMode != AudioStorageMode.ZlibRaw || silentBlock.Payload.Length >= silence.Length)
                throw new InvalidOperationException("Compressible silence was not stored as a smaller ZLIB block.");

            byte[] sourceBytes = new byte[16];
            for (int index = 0; index < sourceBytes.Length; index++)
                sourceBytes[index] = (byte)(index * 37);
            float[] loudSamples = new float[] { 0.81f, -0.81f, 0.9f, -0.9f };
            EncodedAudioBlock loudBlock = encoder.Encode(sourceBytes, sourceBytes.Length, loudSamples, loudSamples.Length);
            if (loudBlock.Payload.Length > sourceBytes.Length)
                throw new InvalidOperationException("Adaptive encoding expanded a block instead of using its raw fallback.");
            if (loudBlock.StorageMode == AudioStorageMode.ZlibCompandedFloat32 && !loudBlock.CompandingApplied)
                throw new InvalidOperationException("The companded storage mode is missing its inverse-transform marker.");
        }

        private static void VerifyTimelineReplay()
        {
            var ring = new AudioTimelineRingBuffer(16, 2);
            byte[][] blocks = new byte[][]
            {
                new byte[] { 0x00, 0x10, 0x00, 0xF0, 0x00, 0x08, 0x00, 0xF8 },
                new byte[] { 0x00, 0x20, 0x00, 0xE0, 0x00, 0x10, 0x00, 0xF0 },
                new byte[] { 0x00, 0x30, 0x00, 0xD0, 0x00, 0x18, 0x00, 0xE8 }
            };

            for (int index = 0; index < blocks.Length; index++)
            {
                AudioTimelineEntry entry = new AudioTimelineEntry
                {
                    QpcPosition = 1000 + index * 100,
                    DevicePosition = 200 + index * 4,
                    ProcessId = 42,
                    OriginalByteLength = blocks[index].Length,
                    FrameCount = 4,
                    Flags = 0,
                    SampleRate = 48000,
                    Channels = 1,
                    BlockAlign = 2,
                    FormatTag = NativeMethods.WaveFormatPcm,
                    BitsPerSample = 16,
                    ValidBitsPerSample = 16,
                    StorageMode = (byte)AudioStorageMode.Raw
                };
                ring.Append(blocks[index], blocks[index].Length, entry);
            }

            if (ring.OldestSequence != 1 || ring.NextSequence != 3)
                throw new InvalidOperationException("Audio and timeline rings did not evict in lockstep.");

            byte[] replay = new byte[8];
            AudioTimelineEntry replayEntry;
            if (ring.TryReadPayload(0, replay, 0, out replayEntry))
                throw new InvalidOperationException("An evicted timeline sequence remained readable.");
            if (!ring.TryReadPayload(1, replay, 0, out replayEntry) || replayEntry.QpcPosition != 1100)
                throw new InvalidOperationException("The retained timeline entry did not align with its audio block.");
            for (int index = 0; index < replay.Length; index++)
            {
                if (replay[index] != blocks[1][index])
                    throw new InvalidOperationException("The ring changed the retained audio bytes.");
            }

            var processor = new SignalProcessor(ring);
            SignalProcessorPass firstPass = processor.ProcessPass(0, 8);
            SignalProcessorPass secondPass = processor.ProcessPass(0, 8);
            if (firstPass.PassNumber != 1 || secondPass.PassNumber != 2
                || firstPass.SegmentsProcessed != 2 || secondPass.SegmentsProcessed != 2
                || firstPass.SamplesProcessed != 8 || secondPass.SamplesProcessed != 8
                || Math.Abs(firstPass.Peak - secondPass.Peak) > 0.000001f)
                throw new InvalidOperationException("The signal processor could not replay the same retained audio twice.");
        }

        private static void VerifyCompressedTimelineReplay()
        {
            var ring = new AudioTimelineRingBuffer(512, 4);
            byte[] rawPcm = new byte[128];
            rawPcm[0] = 0xFF;
            rawPcm[1] = 0x7F;
            byte[] compressedPcm = ZlibCodec.Compress(rawPcm, 0, rawPcm.Length);
            ring.Append(
                compressedPcm,
                compressedPcm.Length,
                new AudioTimelineEntry
                {
                    QpcPosition = 2000,
                    DevicePosition = 1000,
                    ProcessId = 77,
                    OriginalByteLength = rawPcm.Length,
                    FrameCount = 64,
                    SampleRate = 48000,
                    Channels = 1,
                    BlockAlign = 2,
                    FormatTag = NativeMethods.WaveFormatPcm,
                    BitsPerSample = 16,
                    ValidBitsPerSample = 16,
                    StorageMode = (byte)AudioStorageMode.ZlibRaw
                });

            var compander = new FourDCompander();
            float[] original = new float[] { 0.81f, -0.81f, 0.9f, -0.9f };
            float[] companded = new float[original.Length];
            float maximumError;
            if (!compander.TryApply(original, original.Length, companded, out maximumError)
                || maximumError > FourDCompander.MaximumRoundTripError)
                throw new InvalidOperationException("The replay test could not create a valid companded block.");

            byte[] compandedBytes = new byte[original.Length * sizeof(float)];
            Buffer.BlockCopy(companded, 0, compandedBytes, 0, compandedBytes.Length);
            byte[] compressedCompanded = ZlibCodec.Compress(compandedBytes, 0, compandedBytes.Length);
            ring.Append(
                compressedCompanded,
                compressedCompanded.Length,
                new AudioTimelineEntry
                {
                    QpcPosition = 2100,
                    DevicePosition = 1064,
                    ProcessId = 77,
                    OriginalByteLength = original.Length * 2,
                    FrameCount = original.Length,
                    SampleRate = 48000,
                    Channels = 1,
                    BlockAlign = 2,
                    FormatTag = NativeMethods.WaveFormatPcm,
                    BitsPerSample = 16,
                    ValidBitsPerSample = 16,
                    StorageMode = (byte)AudioStorageMode.ZlibCompandedFloat32,
                    CompandingApplied = 1
                });

            var processor = new SignalProcessor(ring);
            SignalProcessorPass first = processor.ProcessPass(0, 4);
            SignalProcessorPass second = processor.ProcessPass(0, 4);
            if (first.SegmentsProcessed != 2 || second.SegmentsProcessed != 2
                || first.SamplesProcessed != 68 || second.SamplesProcessed != 68
                || Math.Abs(first.Peak - second.Peak) > 0.000001f
                || Math.Abs(first.Peak - (32767.0f / 32768.0f)) > 0.0001f)
                throw new InvalidOperationException("ZLIB/companded replay did not reconstruct the same audio on repeated passes.");
        }

        private static void VerifyNamedPipeStreaming()
        {
            string pipeName = "DunguAudioPipe_Test_" + Guid.NewGuid().ToString("N");
            byte[] sourceBytes = new byte[]
            {
                0x00, 0x10, 0x00, 0xF0,
                0x00, 0x08, 0x00, 0xF8,
                0x00, 0x18, 0x00, 0xE8
            };
            var entry = new AudioTimelineEntry
            {
                Sequence = 9,
                QpcPosition = 123456789,
                DevicePosition = 48000,
                ProcessId = 42,
                FrameCount = 3,
                Flags = 0,
                SampleRate = 48000,
                Channels = 2,
                BlockAlign = 4,
                FormatTag = NativeMethods.WaveFormatPcm,
                BitsPerSample = 16,
                ValidBitsPerSample = 16
            };

            using (var broadcaster = new NamedPipeAudioBroadcaster(pipeName, 2))
            using (var client = new NamedPipeClientStream(".", pipeName, PipeDirection.In, PipeOptions.Asynchronous))
            {
                broadcaster.Start();
                if (broadcaster.TryPublish(sourceBytes, entry) || broadcaster.UnconnectedPackets != 1)
                    throw new InvalidOperationException("The pipe retained audio before a receiver connected.");
                client.Connect(3000);

                DateTime deadline = DateTime.UtcNow.AddSeconds(3);
                while (!broadcaster.IsClientConnected && DateTime.UtcNow < deadline)
                    Thread.Sleep(1);
                if (!broadcaster.IsClientConnected)
                    throw new InvalidOperationException("The named-pipe server did not observe the local client connection.");
                if (!broadcaster.TryPublish(sourceBytes, entry))
                    throw new InvalidOperationException("The named-pipe server rejected a packet for its connected client.");

                byte[] header = new byte[AudioPipeProtocol.HeaderSize];
                ReadExactly(client, header);
                if (header[0] != (byte)'D' || header[1] != (byte)'N'
                    || header[2] != (byte)'G' || header[3] != (byte)'U')
                    throw new InvalidOperationException("The named-pipe frame has an invalid DUNGU magic value.");
                if (BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(4, 2)) != AudioPipeProtocol.Version
                    || BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(6, 2)) != AudioPipeProtocol.HeaderSize)
                    throw new InvalidOperationException("The named-pipe frame version or header length is invalid.");
                if (BinaryPrimitives.ReadInt64LittleEndian(header.AsSpan(8, 8)) != entry.Sequence
                    || BinaryPrimitives.ReadInt64LittleEndian(header.AsSpan(16, 8)) != entry.QpcPosition
                    || BinaryPrimitives.ReadInt64LittleEndian(header.AsSpan(24, 8)) != entry.DevicePosition)
                    throw new InvalidOperationException("The named-pipe frame lost its sequence or timeline positions.");
                if (BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(32, 4)) != (uint)entry.ProcessId
                    || BinaryPrimitives.ReadInt32LittleEndian(header.AsSpan(52, 4)) != entry.FrameCount
                    || BinaryPrimitives.ReadInt32LittleEndian(header.AsSpan(56, 4)) != sourceBytes.Length)
                    throw new InvalidOperationException("The named-pipe frame lost its source metadata.");
                if (BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(36, 4)) != (uint)entry.SampleRate
                    || BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(40, 2)) != entry.Channels
                    || BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(42, 2)) != entry.FormatTag
                    || BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(44, 2)) != entry.BitsPerSample
                    || BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(46, 2)) != entry.ValidBitsPerSample
                    || BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(48, 2)) != entry.BlockAlign)
                    throw new InvalidOperationException("The named-pipe frame lost its audio-format metadata.");
                if (header[50] != (byte)AudioStorageMode.Raw || header[51] != 0)
                    throw new InvalidOperationException("The live named-pipe payload must be original, uncompanded audio.");

                byte[] received = new byte[sourceBytes.Length];
                ReadExactly(client, received);
                for (int index = 0; index < sourceBytes.Length; index++)
                {
                    if (received[index] != sourceBytes[index])
                        throw new InvalidOperationException("The named-pipe transport changed audio bytes.");
                }

                byte[] silence = new byte[512];
                var silenceEntry = new AudioTimelineEntry
                {
                    Sequence = 10,
                    QpcPosition = 123456900,
                    DevicePosition = 48003,
                    ProcessId = 42,
                    FrameCount = 128,
                    Flags = NativeMethods.AudioClientBufferFlagSilent,
                    SampleRate = 44100,
                    Channels = 2,
                    BlockAlign = 4,
                    FormatTag = NativeMethods.WaveFormatPcm,
                    BitsPerSample = 16,
                    ValidBitsPerSample = 16
                };
                if (!broadcaster.TryPublish(silence, silenceEntry))
                    throw new InvalidOperationException("The named-pipe server rejected a silent packet.");

                byte[] compressedHeader = new byte[AudioPipeProtocol.HeaderSize];
                ReadExactly(client, compressedHeader);
                int compressedLength = BinaryPrimitives.ReadInt32LittleEndian(compressedHeader.AsSpan(56, 4));
                if (compressedHeader[50] != (byte)AudioStorageMode.ZlibRaw
                    || compressedHeader[51] != 0
                    || compressedLength <= 0
                    || compressedLength >= silence.Length)
                    throw new InvalidOperationException("The pipe did not select its smaller lossless ZLIB representation.");
                byte[] compressedSilence = new byte[compressedLength];
                ReadExactly(client, compressedSilence);
                byte[] expandedSilence = ZlibCodec.Decompress(compressedSilence, 0, compressedLength, silence.Length);
                for (int index = 0; index < expandedSilence.Length; index++)
                {
                    if (expandedSilence[index] != 0)
                        throw new InvalidOperationException("The pipe's ZLIB audio payload did not round-trip.");
                }

                if (broadcaster.TransmittedPackets != 2
                    || broadcaster.TransmittedBytes != sourceBytes.Length + compressedLength)
                    throw new InvalidOperationException("The named-pipe transport did not account for its packet.");
            }
        }

        private static void VerifyPipeCompandedHeader()
        {
            const int SampleCount = 1024;
            byte[] noisySource = new byte[SampleCount * sizeof(double)];
            new Random(7).NextBytes(noisySource);
            var highAmplitude = new float[SampleCount];
            for (int index = 0; index < highAmplitude.Length; index++)
                highAmplitude[index] = (index & 1) == 0 ? 0.9f : -0.9f;

            EncodedAudioBlock encoded = new AudioBlockEncoder().Encode(
                noisySource,
                noisySource.Length,
                highAmplitude,
                highAmplitude.Length);
            if (encoded.StorageMode != AudioStorageMode.ZlibCompandedFloat32 || !encoded.CompandingApplied)
                throw new InvalidOperationException("The encoder did not select a smaller, error-bounded 4-D companded block.");

            var timeline = new AudioTimelineEntry
            {
                Sequence = 4,
                ProcessId = 42,
                FrameCount = SampleCount,
                SampleRate = 44100,
                Channels = 1,
                BlockAlign = sizeof(float),
                FormatTag = NativeMethods.WaveFormatIeeeFloat,
                BitsPerSample = sizeof(float) * 8,
                ValidBitsPerSample = sizeof(float) * 8,
                StorageMode = (byte)encoded.StorageMode,
                CompandingApplied = 1
            };
            byte[] header = AudioPipeProtocol.CreateHeader(timeline, encoded.Payload.Length);
            if (header[50] != (byte)AudioStorageMode.ZlibCompandedFloat32 || header[51] != 1
                || BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(42, 2)) != NativeMethods.WaveFormatIeeeFloat
                || BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(44, 2)) != sizeof(float) * 8
                || BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(48, 2)) != sizeof(float))
                throw new InvalidOperationException("The companded pipe header does not describe its float32 payload.");
        }

        private static void VerifyBoundedPipeQueue()
        {
            var queue = new BoundedAudioPipeQueue(2);
            queue.EnqueueDroppingOldest(new AudioPipePacket(new AudioTimelineEntry { Sequence = 1 }, new byte[] { 1 }));
            queue.EnqueueDroppingOldest(new AudioPipePacket(new AudioTimelineEntry { Sequence = 2 }, new byte[] { 2 }));
            if (!queue.EnqueueDroppingOldest(new AudioPipePacket(new AudioTimelineEntry { Sequence = 3 }, new byte[] { 3 })))
                throw new InvalidOperationException("The bounded pipe queue did not report an eviction.");

            AudioPipePacket first;
            AudioPipePacket second;
            if (!queue.TryDequeue(out first) || !queue.TryDequeue(out second)
                || first.Timeline.Sequence != 2 || second.Timeline.Sequence != 3)
                throw new InvalidOperationException("The bounded pipe queue did not drop the oldest queued packet.");
            if (queue.TryDequeue(out first))
                throw new InvalidOperationException("The bounded pipe queue exceeded its configured capacity.");
        }

        private static void ReadExactly(Stream input, byte[] buffer)
        {
            int offset = 0;
            while (offset < buffer.Length)
            {
                int read = input.Read(buffer, offset, buffer.Length - offset);
                if (read == 0)
                    throw new EndOfStreamException("The named-pipe client disconnected before a full frame was received.");
                offset += read;
            }
        }

        private static void AssertGuid(Type type, string expected)
        {
            if (type.GUID != new Guid(expected))
                throw new InvalidOperationException(type.Name + " has an unexpected interface ID.");
        }

        private static void AssertPeak(float actual, float expected, string formatName)
        {
            if (Math.Abs(actual - expected) > 0.0001f)
                throw new InvalidOperationException(formatName + " peak decoding returned " + actual + " instead of " + expected + ".");
        }

        private static void Write24(IntPtr destination, int offset, int value)
        {
            Marshal.WriteByte(destination, offset, (byte)(value & 0xFF));
            Marshal.WriteByte(destination, offset + 1, (byte)((value >> 8) & 0xFF));
            Marshal.WriteByte(destination, offset + 2, (byte)((value >> 16) & 0xFF));
        }
    }
}
'@

if ($null -eq ('Dungu.ProcessLoopback.NativeProcessLoopbackServer' -as [type])) {
    Add-Type -TypeDefinition $serverCode -ErrorAction Stop
}

if ($CompileOnly) {
    Write-Output 'Embedded C# compiled successfully.'
    return
}

if ($SelfTest) {
    foreach ($check in [Dungu.ProcessLoopback.NativeProcessLoopbackDiagnostics]::RunSelfTests()) {
        Write-Output "PASS $check"
    }
    Write-Output 'All offline tests passed. No audio endpoint was activated and no audio was captured.'
    return
}

if ($null -eq $ProcessId -or $ProcessId.Count -eq 0) {
    [Console]::Error.WriteLine('error: specify one or more target process IDs with -ProcessId, or use -SelfTest/-CompileOnly')
    exit 2
}

if (-not $IsWindows) {
    [Console]::Error.WriteLine('error: process loopback requires Windows.')
    exit 2
}

$windowsBuild = [Environment]::OSVersion.Version.Build
if ($windowsBuild -lt 20348) {
    [Console]::Error.WriteLine("error: process loopback requires Windows build 20348 or newer; this system reports build $windowsBuild.")
    exit 2
}

$seenProcessIds = [System.Collections.Generic.HashSet[int]]::new()
foreach ($targetPid in $ProcessId) {
    if (-not $seenProcessIds.Add($targetPid)) {
        [Console]::Error.WriteLine("error: process ID $targetPid was specified more than once.")
        exit 2
    }
}

$servers = [System.Collections.Generic.List[object]]::new()
$audioRing = $null
$signalProcessor = $null
$exitCode = 0

try {
    $audioRing = [Dungu.ProcessLoopback.AudioTimelineRingBuffer]::new()
    $signalProcessor = [Dungu.ProcessLoopback.SignalProcessor]::new($audioRing)
    Write-Host ("Allocated a shared {0:N0} MiB payload ring and {1:N0} timeline entries." -f
        ($audioRing.CapacityBytes / 1MB),
        $audioRing.TimelineCapacity) -ForegroundColor Cyan

    foreach ($targetPid in $ProcessId) {
        $process = Get-Process -Id $targetPid -ErrorAction Stop
        $server = [Dungu.ProcessLoopback.NativeProcessLoopbackServer]::new(
            [uint32]$targetPid,
            $process.ProcessName,
            -not $ExcludeProcessTree.IsPresent,
            $audioRing,
            $EnablePipe.IsPresent,
            $PipeQueuePackets
        )
        [void]$servers.Add($server)
        $server.Start()
        $treeMode = if ($ExcludeProcessTree) { 'target only' } else { 'process tree' }
        Write-Host "Attached local meter to $($process.ProcessName) (PID $targetPid; $treeMode)." -ForegroundColor Green
        if ($EnablePipe) {
            Write-Host "RX pipe listening at $($server.PipePath); connect one same-user client for raw PCM." -ForegroundColor Cyan
        }
    }

    if ($DurationSeconds -eq 0) {
        Write-Host 'Showing peak levels. Press Ctrl+C to stop.' -ForegroundColor Yellow
    }
    else {
        Write-Host "Showing peak levels for $DurationSeconds seconds." -ForegroundColor Yellow
    }

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    while ($DurationSeconds -eq 0 -or $timer.Elapsed.TotalSeconds -lt $DurationSeconds) {
        foreach ($server in $servers) {
            if ($server.LastError) {
                throw [InvalidOperationException]::new("Capture failed for PID $($server.ProcessId): $($server.LastError)")
            }
            if (-not $server.IsRunning) {
                throw [InvalidOperationException]::new("Capture stopped unexpectedly for PID $($server.ProcessId).")
            }

            $peak = [Math]::Min([Math]::Max([double]$server.ConsumePeak(), 0.0), 1.0)
            $barLength = [int][Math]::Round($peak * 40)
            $bar = '#' * $barLength
            [Console]::WriteLine(
                '{0,-16} PID {1,7} | {2,-40} {3,6:P1}',
                $server.ProcessName,
                $server.ProcessId,
                $bar,
                $peak
            )
        }
        Start-Sleep -Milliseconds 50
    }
}
catch [System.Management.Automation.PipelineStoppedException] {
    Write-Host 'Stopping capture.' -ForegroundColor Yellow
}
catch {
    $exitCode = 1
    $errorToReport = $_.Exception.GetBaseException()
    [Console]::Error.WriteLine("error: $($errorToReport.Message)")
}
finally {
    foreach ($server in $servers) {
        $server.Dispose()
        if ($EnablePipe) {
            $pipeSummary = "Pipe PID {0}: sent {1} packets ({2:N0} bytes), dropped {3}, no-client {4}, disconnects {5}." -f
                $server.ProcessId,
                $server.PipeTransmittedPackets,
                $server.PipeTransmittedBytes,
                $server.PipeDroppedPackets,
                $server.PipeUnconnectedPackets,
                $server.PipeClientDisconnects
            Write-Host $pipeSummary
        }
        if ($server.LastError -and $exitCode -eq 0) {
            $exitCode = 1
            [Console]::Error.WriteLine("error: capture cleanup for PID $($server.ProcessId): $($server.LastError)")
        }
    }
}

if ($null -ne $audioRing) {
    $bufferedSavingsPercent = 0.0
    if ($audioRing.BufferedOriginalBytes -gt 0) {
        $bufferedSavingsPercent = 100.0 * (
            1.0 - ([double]$audioRing.BufferedStoredBytes / $audioRing.BufferedOriginalBytes)
        )
    }
    $bufferSummary = "Retained {0:N1} MiB encoded of {1:N1} MiB source audio ({2:N1}% current saving; {3:N1}% lifetime saving)." -f
        ($audioRing.BufferedStoredBytes / 1MB),
        ($audioRing.BufferedOriginalBytes / 1MB),
        $bufferedSavingsPercent,
        $audioRing.TotalSavingsPercent
    Write-Host $bufferSummary
}

if ($ReplayPasses -gt 0 -and $exitCode -eq 0 -and $null -ne $audioRing) {
    $replayStart = $audioRing.OldestSequence
    for ($pass = 1; $pass -le $ReplayPasses; $pass++) {
        $result = $signalProcessor.ProcessPass($replayStart, $audioRing.TimelineCapacity)
        $passSummary = "Replay pass {0}: {1} blocks, {2} samples, peak {3:P1}, expired {4}." -f `
            $result.PassNumber, $result.SegmentsProcessed, $result.SamplesProcessed, $result.Peak, $result.SegmentsExpired
        Write-Host $passSummary
    }
}

if ($exitCode -ne 0) {
    exit $exitCode
}
