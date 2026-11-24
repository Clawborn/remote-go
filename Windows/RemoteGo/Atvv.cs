using System.Buffers.Binary;

namespace RemoteGo;

internal sealed record VoiceFormat(bool Modern, byte Codec, int FrameBytes)
{
    internal static VoiceFormat? Read(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length < 7 || bytes[0] != 0x0b) return null;
        var version = BinaryPrimitives.ReadUInt16BigEndian(bytes[1..]);
        if (version != 0x100 && (version != 4 || bytes.Length < 9)) return null;
        var modern = version == 0x100;
        var codecs = bytes[modern ? 3 : 4];
        var size = BinaryPrimitives.ReadUInt16BigEndian(bytes[5..]);
        if ((codecs & 3) == 0 || size <= (modern ? 0 : 6) || size > 1024) return null;
        return new(modern, (byte)((codecs & 2) != 0 ? 2 : 1), size);
    }

    internal byte[] Open => Modern ? [0x0c, 0] : [0x0c, 0, Codec];
    internal byte[] Close(byte stream) => Modern ? [0x0d, stream] : [0x0d];
}

internal sealed class AtvvDecoder
{
    private static readonly int[] Steps =
    [
        7,8,9,10,11,12,13,14,16,17,19,21,23,25,28,31,34,37,41,45,50,55,60,66,73,80,88,97,
        107,118,130,143,157,173,190,209,230,253,279,307,337,371,408,449,494,544,598,658,724,
        796,876,963,1060,1166,1282,1411,1552,1707,1878,2066,2272,2499,2749,3024,3327,3660,
        4026,4428,4871,5358,5894,6484,7132,7845,8630,9493,10442,11487,12635,13899,15289,
        16818,18500,20350,22385,24623,27086,29794,32767
    ];
    private static readonly int[] Changes = [-1,-1,-1,-1,2,4,6,8];
    private int predictor, index;
    private short? previous;
    private readonly List<byte> pending = [];
    internal byte Codec { get; private set; }

    internal void Reset(byte codec)
    {
        pending.Clear();
        predictor = index = 0;
        previous = null;
        Codec = codec;
    }

    internal void Synchronize(byte codec, short sample, byte step)
    {
        pending.Clear();
        if (Codec != codec) previous = null;
        Codec = codec;
        predictor = sample;
        index = Math.Min((int)step, 88);
    }

    internal byte[] Convert(byte[] packet, VoiceFormat format)
    {
        pending.AddRange(packet);
        var output = new List<short>();
        while (pending.Count >= format.FrameBytes)
        {
            var frame = pending.GetRange(0, format.FrameBytes);
            pending.RemoveRange(0, format.FrameBytes);
            var dataOffset = 0;
            if (!format.Modern)
            {
                predictor = (short)(frame[3] << 8 | frame[4]);
                index = Math.Min((int)frame[5], 88);
                Append((short)predictor, output);
                dataOffset = 6;
            }
            for (var i = dataOffset; i < frame.Count; i++)
            {
                Append(Decode(frame[i] >> 4), output);
                Append(Decode(frame[i] & 15), output);
            }
        }
        var pcm = new byte[2 * output.Count];
        for (var i = 0; i < output.Count; i++)
            BinaryPrimitives.WriteInt16LittleEndian(pcm.AsSpan(i * 2), output[i]);
        return pcm;
    }

    private short Decode(int nibble)
    {
        var step = Steps[index];
        var delta = (step >> 3) + ((nibble & 4) != 0 ? step : 0)
            + ((nibble & 2) != 0 ? step >> 1 : 0) + ((nibble & 1) != 0 ? step >> 2 : 0);
        predictor = Math.Clamp(predictor + ((nibble & 8) != 0 ? -delta : delta), short.MinValue, short.MaxValue);
        index = Math.Clamp(index + Changes[nibble & 7], 0, 88);
        return (short)predictor;
    }

    private void Append(short value, List<short> output)
    {
        if (Codec == 1) output.Add((short)(((previous ?? value) + value) / 2));
        output.Add(value);
        previous = value;
    }
}
