using System.Buffers.Binary;
using System.Runtime.InteropServices;

namespace RemoteGo;

internal sealed class RawRemote
{
    internal const int InputMessage = 0xff, DeviceMessage = 0xfe;
    private const uint Hid = 2, Input = 0x10000003, DeviceInfo = 0x2000000b;
    private static readonly int HeaderBytes = 8 + 2 * IntPtr.Size;
    private readonly Dictionary<nint, bool> devices = new();
    private readonly Dictionary<nint, HashSet<ButtonId>> held = new();
    internal event Action<ButtonId, bool>? Edge;
    internal event Action<int>? Connection;

    internal bool Start(nint window)
    {
        RawInputDevice[] registrations = [new() { Page = 0x0c, Usage = 0, Flags = 0x2120, Window = window }];
        if (!RegisterRawInputDevices(registrations, 1, (uint)Marshal.SizeOf<RawInputDevice>())) return false;
        uint count = 0;
        var size = (uint)Marshal.SizeOf<DeviceEntry>();
        if (GetRawInputDeviceList(null, ref count, size) == 0 && count is > 0 and <= 4096)
        {
            var list = new DeviceEntry[count];
            if (GetRawInputDeviceList(list, ref count, size) != uint.MaxValue)
                foreach (var item in list.Where(item => item.Type == Hid)) Check(item.Handle);
        }
        PublishConnections();
        return true;
    }

    internal void DeviceChanged(nint change, nint device)
    {
        if (change == 1)
        {
            Check(device);
        }
        else if (change == 2)
        {
            devices.Remove(device);
            if (held.Remove(device, out var before))
                foreach (var key in before.Where(key => !IsHeld(key))) Edge?.Invoke(key, false);
        }
        PublishConnections();
    }

    internal void Receive(nint message)
    {
        uint bytes = 0;
        if (GetRawInputData(message, Input, null, ref bytes, (uint)HeaderBytes) == uint.MaxValue
            || bytes < HeaderBytes + 8 || bytes > 65536)
            return;
        var buffer = new byte[bytes];
        if (GetRawInputData(message, Input, buffer, ref bytes, (uint)HeaderBytes) != bytes) return;
        if (BinaryPrimitives.ReadUInt32LittleEndian(buffer) != Hid) return;
        var device = IntPtr.Size == 8 ? (nint)BinaryPrimitives.ReadInt64LittleEndian(buffer.AsSpan(8))
            : (nint)BinaryPrimitives.ReadInt32LittleEndian(buffer.AsSpan(8));
        if (!Check(device)) return;
        var size = BinaryPrimitives.ReadUInt32LittleEndian(buffer.AsSpan(HeaderBytes));
        var count = BinaryPrimitives.ReadUInt32LittleEndian(buffer.AsSpan(HeaderBytes + 4));
        if (size is < 2 or > 512 || count == 0 || (ulong)size * count > (ulong)bytes - (ulong)HeaderBytes - 8) return;

        for (var i = 0; i < (int)count; i++)
        {
            var report = buffer.AsSpan(HeaderBytes + 8 + i * (int)size, (int)size);
            if (RemoteButtons.DecodeReport(report) is { } keys) Apply(device, keys);
        }
    }

    private void Apply(nint device, ButtonId[] buttons)
    {
        var before = held[device];
        held[device] = [.. buttons];
        foreach (var key in before)
            if (!IsHeld(key)) Edge?.Invoke(key, false);
        foreach (var key in buttons)
            if (!before.Contains(key) && !held.Any(item => item.Key != device && item.Value.Contains(key)))
                Edge?.Invoke(key, true);
    }

    private bool Check(nint device)
    {
        if (device == 0) return false;
        if (devices.TryGetValue(device, out var match)) return match;
        var data = new byte[32];
        BinaryPrimitives.WriteUInt32LittleEndian(data, 32);
        uint length = (uint)data.Length;
        var result = GetRawInputDeviceInfo(device, DeviceInfo, data, ref length);
        match = result >= 24 && result != uint.MaxValue
            && BinaryPrimitives.ReadUInt32LittleEndian(data.AsSpan(4)) == Hid
            && (BinaryPrimitives.ReadUInt32LittleEndian(data.AsSpan(8)) & 0xffff) == 0x18d1
            && BinaryPrimitives.ReadUInt32LittleEndian(data.AsSpan(12)) == 0x9450;
        devices[device] = match;
        if (match)
        {
            held[device] = [];
            PublishConnections();
        }
        return match;
    }

    private bool IsHeld(ButtonId button) => held.Values.Any(keys => keys.Contains(button));
    private void PublishConnections() => Connection?.Invoke(devices.Values.Count(value => value));

    [StructLayout(LayoutKind.Sequential)]
    private struct RawInputDevice { internal ushort Page, Usage; internal uint Flags; internal nint Window; }
    [StructLayout(LayoutKind.Sequential)]
    private struct DeviceEntry { internal nint Handle; internal uint Type; }
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterRawInputDevices(RawInputDevice[] devices, uint count, uint size);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint GetRawInputData(nint input, uint command, [Out] byte[]? data, ref uint size, uint headerSize);
    [DllImport("user32.dll", EntryPoint = "GetRawInputDeviceInfoW", SetLastError = true)]
    private static extern uint GetRawInputDeviceInfo(nint device, uint command, [In, Out] byte[] data, ref uint size);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint GetRawInputDeviceList([Out] DeviceEntry[]? list, ref uint count, uint size);
}

internal sealed class Output
{
    private const uint Extended = 1, KeyUp = 2, Move = 1, LeftDown = 2, LeftUp = 4, Wheel = 0x800;
    private readonly Dictionary<ushort, (int Count, bool OwnsKey)> pressed = new();
    internal event Action? Failed;

    internal Action? Press(Shortcut chord)
    {
        if (chord.Key is 0 or > 254) return null;
        var keys = ChordKeys(chord);
        var events = new List<InputEvent>(keys.Length);
        foreach (var key in keys)
        {
            if (pressed.TryGetValue(key, out var previous))
            {
                pressed[key] = (previous.Count + 1, previous.OwnsKey);
                continue;
            }
            var owns = (GetAsyncKeyState(key) & 0x8000) == 0;
            pressed[key] = (1, owns);
            if (owns) events.Add(Key(key, false));
        }
        if (!Send([.. events]))
        {
            Release(keys);
            return null;
        }
        return () => Release(keys);
    }

    internal void Tap(Shortcut chord) => Press(chord)?.Invoke();
    internal void Repeat(Shortcut chord)
    {
        if (pressed.TryGetValue(chord.Key, out var record) && record.OwnsKey) Send([Key(chord.Key, false)]);
    }

    internal void MoveBy(int x, int y) => Send([Mouse(Move, x, y)]);
    internal void Click(bool down) => Send([Mouse(down ? LeftDown : LeftUp)]);
    internal void Scroll(int delta) => Send([Mouse(Wheel, data: unchecked((uint)delta))]);

    private static ushort[] ChordKeys(Shortcut chord)
    {
        var keys = new List<ushort>(5);
        if (chord.Mods.HasFlag(KeyMods.Control)) keys.Add(0xa2);
        if (chord.Mods.HasFlag(KeyMods.Shift)) keys.Add(0xa0);
        if (chord.Mods.HasFlag(KeyMods.Alt)) keys.Add(0xa4);
        if (chord.Mods.HasFlag(KeyMods.Windows)) keys.Add(0x5b);
        if (!keys.Contains(chord.Key)) keys.Add(chord.Key);
        return [.. keys];
    }

    private void Release(ushort[] keys)
    {
        var events = new List<InputEvent>(keys.Length);
        foreach (var key in keys.Reverse())
        {
            if (!pressed.TryGetValue(key, out var previous)) continue;
            if (previous.Count > 1) pressed[key] = (previous.Count - 1, previous.OwnsKey);
            else
            {
                pressed.Remove(key);
                if (previous.OwnsKey) events.Add(Key(key, true));
            }
        }
        Send([.. events]);
    }

    private bool Send(InputEvent[] events)
    {
        if (events.Length == 0 || SendInput((uint)events.Length, events, Marshal.SizeOf<InputEvent>()) == events.Length)
            return true;
        Failed?.Invoke();
        return false;
    }

    private static InputEvent Key(ushort key, bool up) => new()
    {
        Type = 1, Data = new() { Keyboard = new() { Vk = key, Flags = (up ? KeyUp : 0)
            | (key is 0x21 or 0x22 or 0x23 or 0x24 or 0x25 or 0x26 or 0x27 or 0x28 or 0x2d or 0x2e
                or 0x5b or 0x5c or 0xa3 or 0xa5 ? Extended : 0) } }
    };

    private static InputEvent Mouse(uint flags, int x = 0, int y = 0, uint data = 0) => new()
    {
        Data = new() { Mouse = new() { X = x, Y = y, Flags = flags, Data = data } }
    };

    [StructLayout(LayoutKind.Sequential)]
    private struct InputEvent { internal uint Type; internal InputUnion Data; }
    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] internal KeyboardInput Keyboard;
        [FieldOffset(0)] internal MouseInput Mouse;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct KeyboardInput { internal ushort Vk, Scan; internal uint Flags, Time; internal nuint Extra; }
    [StructLayout(LayoutKind.Sequential)]
    private struct MouseInput { internal int X, Y; internal uint Data, Flags, Time; internal nuint Extra; }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint count, InputEvent[] input, int size);
    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int key);
}
