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

    [switch]$CompileOnly,

    [switch]$SelfTest
)

$serverCode = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
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
        internal const int AudioClientBufferFlagSilent = 0x00000002;

        internal static readonly Guid PcmSubFormat = new Guid("00000001-0000-0010-8000-00AA00389B71");
        internal static readonly Guid IeeeFloatSubFormat = new Guid("00000003-0000-0010-8000-00AA00389B71");
        internal static readonly Guid AudioClientInterfaceId = new Guid("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2");
        internal static readonly Guid AudioCaptureClientInterfaceId = new Guid("C8ADBD64-E71E-48A0-A4DE-185C395CD317");

        [DllImport("Mmdevapi.dll", CharSet = CharSet.Unicode, ExactSpelling = true, PreserveSig = true)]
        internal static extern int ActivateAudioInterfaceAsync(
            [MarshalAs(UnmanagedType.LPWStr)] string deviceInterfacePath,
            [MarshalAs(UnmanagedType.LPStruct)] Guid interfaceId,
            IntPtr activationParams,
            [MarshalAs(UnmanagedType.Interface)] IActivateAudioInterfaceCompletionHandler completionHandler,
            out IActivateAudioInterfaceAsyncOperation activationOperation);

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

        private AudioSampleFormat(int encoding, int channels, int containerBits, int validBits, int blockAlign)
        {
            if (channels <= 0)
                throw new NotSupportedException("The mix format reports no audio channels.");
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
                format.BlockAlign);
        }

        internal static AudioSampleFormat CreateForTesting(int encoding, int channels, int containerBits, int validBits, int blockAlign)
        {
            return new AudioSampleFormat(encoding, channels, containerBits, validBits, blockAlign);
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
    }

    public sealed class NativeProcessLoopbackServer : IDisposable
    {
        private const int SharedMode = 0;
        private const int BufferDurationHns = 1000000;
        private const int ActivationTimeoutSeconds = 30;

        private readonly bool _includeProcessTree;
        private readonly ManualResetEventSlim _stopRequested = new ManualResetEventSlim(false);
        private readonly TaskCompletionSource<bool> _startup =
            new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);

        private Thread _captureThread;
        private Exception _lastError;
        private int _startState;
        private int _disposed;
        private int _running;
        private int _peakBits;

        public uint ProcessId { get; private set; }
        public string ProcessName { get; private set; }
        public bool IsRunning { get { return Volatile.Read(ref _running) != 0; } }
        public string LastError
        {
            get
            {
                Exception error = Volatile.Read(ref _lastError);
                return error == null ? null : error.GetType().Name + ": " + error.Message;
            }
        }

        public NativeProcessLoopbackServer(uint targetProcessId, string processName, bool includeProcessTree)
        {
            if (targetProcessId == 0)
                throw new ArgumentOutOfRangeException("targetProcessId");
            if (String.IsNullOrWhiteSpace(processName))
                throw new ArgumentException("A process name is required.", "processName");

            ProcessId = targetProcessId;
            ProcessName = processName;
            _includeProcessTree = includeProcessTree;
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

                IntPtr formatPointer = IntPtr.Zero;
                int formatResult = audioClient.GetMixFormat(out formatPointer);
                try
                {
                    NativeMethods.ThrowIfFailed(formatResult, "IAudioClient.GetMixFormat");
                    sampleFormat = AudioSampleFormat.FromNative(formatPointer);
                    NativeMethods.ThrowIfFailed(
                        audioClient.Initialize(
                            SharedMode,
                            NativeMethods.AudioClientStreamFlagsLoopback,
                            BufferDurationHns,
                            0,
                            formatPointer,
                            IntPtr.Zero),
                        "IAudioClient.Initialize");
                }
                finally
                {
                    if (formatPointer != IntPtr.Zero)
                        Marshal.FreeCoTaskMem(formatPointer);
                }

                object captureObject;
                Guid captureClientId = NativeMethods.AudioCaptureClientInterfaceId;
                NativeMethods.ThrowIfFailed(
                    audioClient.GetService(ref captureClientId, out captureObject),
                    "IAudioClient.GetService(IAudioCaptureClient)");
                captureClient = captureObject as IAudioCaptureClient;
                if (captureClient == null)
                    throw new InvalidCastException("IAudioClient.GetService did not return IAudioCaptureClient.");

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

                    float peak = 0;
                    try
                    {
                        if ((flags & NativeMethods.AudioClientBufferFlagSilent) == 0)
                            peak = sampleFormat.MeasurePeak(data, frames);
                    }
                    finally
                    {
                        NativeMethods.ThrowIfFailed(captureClient.ReleaseBuffer(frames), "IAudioCaptureClient.ReleaseBuffer");
                    }

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
    Write-Output 'All offline process-loopback self-tests passed. No capture was started.'
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
$exitCode = 0

try {
    foreach ($targetPid in $ProcessId) {
        $process = Get-Process -Id $targetPid -ErrorAction Stop
        $server = [Dungu.ProcessLoopback.NativeProcessLoopbackServer]::new(
            [uint32]$targetPid,
            $process.ProcessName,
            -not $ExcludeProcessTree.IsPresent
        )
        [void]$servers.Add($server)
        $server.Start()
        $treeMode = if ($ExcludeProcessTree) { 'target only' } else { 'process tree' }
        Write-Host "Attached local meter to $($process.ProcessName) (PID $targetPid; $treeMode)." -ForegroundColor Green
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
        if ($server.LastError -and $exitCode -eq 0) {
            $exitCode = 1
            [Console]::Error.WriteLine("error: capture cleanup for PID $($server.ProcessId): $($server.LastError)")
        }
    }
}

if ($exitCode -ne 0) {
    exit $exitCode
}
