using System.IO;
using System.Buffers.Binary;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Devices.Enumeration;
using Windows.Storage.Streams;

namespace RemoteGo;

internal sealed class VoiceOutput : IDisposable
{
    private WasapiOut? player;
    private BufferedWaveProvider? buffer;
    private MMDevice? destination;
    internal bool Active => player != null;

    internal static AppEntry[] Devices()
    {
        using var enumerator = new MMDeviceEnumerator();
        return enumerator.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active)
            .Select(device =>
            {
                using (device) return new AppEntry(device.ID, device.FriendlyName);
            }).ToArray();
    }

    internal void Start(string device)
    {
        Dispose();
        using var enumerator = new MMDeviceEnumerator();
        destination = enumerator.GetDevice(device);
        try
        {
            buffer = new BufferedWaveProvider(new WaveFormat(16000, 16, 1))
                { BufferDuration = TimeSpan.FromMilliseconds(400), DiscardOnBufferOverflow = true };
            player = new WasapiOut(destination, AudioClientShareMode.Shared, true, 40);
            player.Init(buffer);
            player.Play();
        }
        catch
        {
            Dispose();
            throw;
        }
    }

    internal void Receive(byte[] samples)
    {
        if (samples.Length > 0) buffer?.AddSamples(samples, 0, samples.Length);
    }

    public void Dispose()
    {
        player?.Dispose();
        player = null;
        buffer = null;
        destination?.Dispose();
        destination = null;
    }
}

internal sealed class VoiceInput : IDisposable
{
    private static Guid Uuid(int id) => new($"ab5e000{id}-5a21-4f05-bc7d-af01f617b664");
    private readonly CancellationTokenSource shutdown = new();
    private readonly System.Windows.Forms.Timer watchdog = new() { Interval = 250 };
    private readonly SemaphoreSlim writes = new(1);
    private readonly AtvvDecoder decoder = new();
    private BluetoothLEDevice? device;
    private GattDeviceService? service;
    private GattCharacteristic? tx, audio, control;
    private VoiceFormat? format;
    private byte? stream, press;
    private bool wanted, opening, disposed, connecting;
    private long lastPacket, lastPing, pressedAt;
    private SynchronizationContext? ui;
    internal event Action<bool>? Button;
    internal event Action<string>? Status;
    internal event Action<byte[]>? Samples;
    internal event Action? Interrupted;
    internal bool Ready => format != null;

    internal void Start()
    {
        if (ui != null) return;
        ui = SynchronizationContext.Current ?? throw new InvalidOperationException("UI context is required.");
        watchdog.Tick += (_, _) => Tick();
        watchdog.Start();
        _ = Reconnect(shutdown.Token);
    }

    private async Task Reconnect(CancellationToken cancel)
    {
        while (!cancel.IsCancellationRequested)
        {
            try
            {
                if (device == null)
                {
                    var found = await DeviceInformation.FindAllAsync(
                        BluetoothLEDevice.GetDeviceSelectorFromPairingState(true));
                    if (cancel.IsCancellationRequested) return;
                    var match = found.FirstOrDefault(item => item.Name.Contains("Chromecast", StringComparison.OrdinalIgnoreCase)
                        && item.Name.Contains("Remote", StringComparison.OrdinalIgnoreCase));
                    if (match != null) await Connect(match, cancel);
                }
            }
            catch (Exception error) when (!cancel.IsCancellationRequested)
            {
                Disconnect();
                Status?.Invoke($"ATVV · {error.Message}");
            }
            catch (Exception) when (cancel.IsCancellationRequested) { return; }

            try { await Task.Delay(2500, cancel); }
            catch (OperationCanceledException) { return; }
        }
    }

    private async Task Connect(DeviceInformation info, CancellationToken cancel)
    {
        connecting = true;
        try
        {
            device = await BluetoothLEDevice.FromIdAsync(info.Id);
            if (disposed) { Disconnect(); return; }
            if (device == null) return;
            var services = await device.GetGattServicesForUuidAsync(Uuid(1), BluetoothCacheMode.Uncached);
            if (cancel.IsCancellationRequested) return;
            if (services.Status != GattCommunicationStatus.Success || services.Services.Count == 0)
                throw new IOException("ATVV service was not found.");
            service = services.Services[0];
            foreach (var extra in services.Services.Skip(1)) extra.Dispose();
            var characteristics = await service.GetCharacteristicsAsync(BluetoothCacheMode.Uncached);
            if (cancel.IsCancellationRequested) return;
            if (characteristics.Status != GattCommunicationStatus.Success)
                throw new IOException("ATVV characteristics are unavailable.");
            tx = characteristics.Characteristics.FirstOrDefault(item => item.Uuid == Uuid(2));
            audio = characteristics.Characteristics.FirstOrDefault(item => item.Uuid == Uuid(3));
            control = characteristics.Characteristics.FirstOrDefault(item => item.Uuid == Uuid(4));
            if (tx == null || audio == null || control == null) throw new IOException("ATVV channels are incomplete.");
            control.ValueChanged += Changed;
            audio.ValueChanged += Changed;
            await Subscribe(control);
            if (cancel.IsCancellationRequested) return;
            await Subscribe(audio);
            if (cancel.IsCancellationRequested) return;
            device.ConnectionStatusChanged += ConnectionChanged;
            lastPacket = Environment.TickCount64;
            await Write([0x0a, 1, 0, 0, 3, 3]);
        }
        finally { connecting = false; }
    }

    private static async Task Subscribe(GattCharacteristic characteristic)
    {
        var mode = characteristic.CharacteristicProperties.HasFlag(GattCharacteristicProperties.Notify)
            ? GattClientCharacteristicConfigurationDescriptorValue.Notify
            : GattClientCharacteristicConfigurationDescriptorValue.Indicate;
        if (await characteristic.WriteClientCharacteristicConfigurationDescriptorAsync(mode) != GattCommunicationStatus.Success)
            throw new IOException("ATVV notification subscription failed.");
    }

    private void ConnectionChanged(BluetoothLEDevice sender, object args)
    {
        ui?.Post(_ =>
        {
            if (device == sender && sender.ConnectionStatus == BluetoothConnectionStatus.Disconnected) Disconnect();
        }, null);
    }

    private void Changed(GattCharacteristic sender, GattValueChangedEventArgs args)
    {
        if (args.CharacteristicValue.Length is 0 or > 2048) return;
        using var reader = DataReader.FromBuffer(args.CharacteristicValue);
        var bytes = new byte[reader.UnconsumedBufferLength];
        reader.ReadBytes(bytes);
        ui?.Post(_ =>
        {
            if (disposed) return;
            if (sender == control || (sender == audio && format == null && VoiceFormat.Read(bytes) != null))
                ReceiveControl(bytes);
            else if (sender == audio && stream != null && format is { } available)
            {
                lastPacket = Environment.TickCount64;
                Samples?.Invoke(decoder.Convert(bytes, available));
            }
        }, null);
    }

    private void ReceiveControl(byte[] bytes)
    {
        if (bytes[0] == 0x0b)
        {
            format = VoiceFormat.Read(bytes);
            Status?.Invoke(format == null ? "遥控器音频格式不兼容" : "遥控器语音已连接");
            if (wanted) Request();
            return;
        }

        if (bytes.Length >= 4 && bytes[0] == 4 && bytes[1] == 3 && press == null)
        {
            press = bytes[3];
            pressedAt = lastPing = Environment.TickCount64;
            Button?.Invoke(true);
        }
        if (bytes is [0, 2, ..]) ReleaseButton();

        switch (bytes[0])
        {
            case 0x08:
                if (wanted) Request();
                break;
            case 0x04:
                if (wanted && format is { } available && stream == null &&
                    (!available.Modern || (bytes.Length >= 4 && bytes[2] is 1 or 2)))
                {
                    opening = false;
                    stream = available.Modern ? bytes[3] : (byte)0;
                    decoder.Reset(available.Modern ? bytes[2] : available.Codec);
                    lastPing = lastPacket = Environment.TickCount64;
                }
                break;
            case 0x00:
                stream = null;
                opening = false;
                if (wanted && bytes is not [0, 2, ..] and not [0, 4, ..]) Interrupted?.Invoke();
                break;
            case 0x0a when stream != null && format?.Modern == true && bytes.Length >= 7 && bytes[1] is 1 or 2:
                decoder.Synchronize(bytes[1], BinaryPrimitives.ReadInt16BigEndian(bytes.AsSpan(4)), bytes[6]);
                break;
            case 0x0c:
                stream = null;
                opening = false;
                if (wanted) Interrupted?.Invoke();
                break;
        }
    }

    internal void Capture(bool value)
    {
        wanted = value;
        if (value) Request();
        else if ((opening || stream.HasValue) && format is { } available)
        {
            Send(available.Close(stream.GetValueOrDefault()));
            opening = false;
            stream = null;
        }
    }

    private void Request()
    {
        if (opening || stream != null || format is not { } available) return;
        opening = true;
        lastPacket = Environment.TickCount64;
        Send(available.Open);
    }

    private void Tick()
    {
        var now = Environment.TickCount64;
        if (!connecting && device != null && format == null && now - lastPacket > 10000)
        {
            Disconnect();
            Status?.Invoke("遥控器语音连接超时，正在重试");
        }
        else if (press != null && !wanted && now - pressedAt >= 45000)
            ReleaseButton();

        if ((opening && now - lastPacket > 4000) || (stream != null && now - lastPacket > 2500))
        {
            Capture(false);
            Interrupted?.Invoke();
            Status?.Invoke("遥控器音频已中断");
        }
        if (format?.Modern == true && (stream ?? press) is byte id && now - lastPing >= 2500)
        {
            lastPing = now;
            Send([0x0e, id]);
        }
    }

    private async void Send(byte[] bytes)
    {
        try { await Write(bytes); }
        catch (Exception) when (disposed) { }
        catch (Exception error) { Disconnect(); Status?.Invoke($"ATVV · {error.Message}"); }
    }

    private async Task Write(byte[] bytes)
    {
        var characteristic = tx;
        if (characteristic == null) return;
        await writes.WaitAsync();
        try
        {
            if (tx != characteristic || disposed) return;
            using var writer = new DataWriter();
            writer.WriteBytes(bytes);
            var option = characteristic.CharacteristicProperties.HasFlag(GattCharacteristicProperties.Write)
                ? GattWriteOption.WriteWithResponse : GattWriteOption.WriteWithoutResponse;
            if (await characteristic.WriteValueAsync(writer.DetachBuffer(), option) != GattCommunicationStatus.Success
                && tx == characteristic && !disposed) throw new IOException("The remote rejected the ATVV command.");
        }
        finally { writes.Release(); }
    }

    private void ReleaseButton()
    {
        if (!press.HasValue) return;
        press = null;
        Button?.Invoke(false);
    }

    private void Disconnect()
    {
        var wasConnected = device != null || wanted;
        wanted = opening = false;
        format = null;
        stream = null;
        tx = null;
        if (control != null) control.ValueChanged -= Changed;
        if (audio != null) audio.ValueChanged -= Changed;
        if (device != null) device.ConnectionStatusChanged -= ConnectionChanged;
        control = audio = null;
        service?.Dispose();
        service = null;
        device?.Dispose();
        device = null;
        ReleaseButton();
        if (wasConnected) Interrupted?.Invoke();
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        shutdown.Cancel();
        watchdog.Dispose();
        Disconnect();
    }
}
