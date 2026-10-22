using System.Globalization;
using System.Text.Json;
using HIDMaestro;
internal static class StateAdapter
{
    internal static readonly HMAxis[] Axes = [HMAxis.X, HMAxis.Y, HMAxis.Rx, HMAxis.Ry, HMAxis.Vx, HMAxis.Vy];
    internal static void Exact(JsonElement value, params string[] keys)
    {
        if (value.ValueKind != JsonValueKind.Object) throw new InvalidDataException();
        var names = value.EnumerateObject().Select(p => p.Name).ToArray();
        if (names.Length != keys.Length || names.Distinct().Count() != names.Length || names.Except(keys).Any()) throw new InvalidDataException();
    }
    internal static uint Integer(JsonElement value) => value.ValueKind == JsonValueKind.Number && uint.TryParse(value.GetRawText(), NumberStyles.None, CultureInfo.InvariantCulture, out var result) ? result : throw new InvalidDataException();
    internal static string Report(JsonElement value)
    {
        var text = value.GetProperty("reportHex").GetString() ?? throw new InvalidDataException();
        if (text.Length != 40 || text.Any(c => !(c is >= '0' and <= '9' or >= 'a' and <= 'f'))) throw new InvalidDataException();
        return text;
    }
    internal static HMGamepadState Adapt(JsonElement frame)
    {
        Exact(frame, "version", "reportHex", "axes", "buttons", "hat");
        if (Integer(frame.GetProperty("version")) != 1) throw new InvalidDataException();
        _ = Report(frame);
        var input = frame.GetProperty("axes");
        if (input.ValueKind != JsonValueKind.Array || input.GetArrayLength() != 6) throw new InvalidDataException();
        var axes = new Dictionary<HMAxis, float>();
        foreach (var axis in input.EnumerateArray())
        {
            Exact(axis, "usage", "bits");
            var usage = Integer(axis.GetProperty("usage"));
            if (usage > ushort.MaxValue) throw new InvalidDataException();
            var name = (HMAxis)usage;
            var unit = BitConverter.UInt32BitsToSingle(Integer(axis.GetProperty("bits")));
            if (!Axes.Contains(name) || !float.IsFinite(unit) || unit < 0 || unit > 1 || !axes.TryAdd(name, unit)) throw new InvalidDataException();
        }
        var buttons = Integer(frame.GetProperty("buttons")); var hat = Integer(frame.GetProperty("hat"));
        if ((buttons & ~0x7ffu) != 0 || hat > 8) throw new InvalidDataException();
        // Values already use SDK-downward Y. No second inversion, deadzone or clamp.
        return new HMGamepadState { Axes = axes, Buttons = (HMButton)buttons, Hat = (HMHat)hat };
    }
}
