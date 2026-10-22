using System.Buffers.Binary;
using System.Reflection;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using HIDMaestro;
try
{
    if (args.Length != 2) throw new InvalidDataException();
    var source = File.ReadAllBytes(args[1]);
    if (Convert.ToHexStringLower(SHA256.HashData(source)) != "679aa37d80bb5554343fad383e1c420796a3e1f07e221437fc8e62292df5717c") throw new InvalidDataException();
    using var profile = JsonDocument.Parse(source);
    var layout = profile.RootElement.GetProperty("layout");
    if (profile.RootElement.GetProperty("id").GetString() != "xbox-360-wired" || profile.RootElement.GetProperty("xinput").GetProperty("via").GetString() != "xusbCompanion" || layout.GetProperty("triggers")[0].GetProperty("axis").GetString() != "Vx" || layout.GetProperty("triggers")[1].GetProperty("axis").GetString() != "Vy") throw new InvalidDataException();
    var assembly = Assembly.GetExecutingAssembly();
    foreach (var forbidden in new[] { "HMContext", "HMController", "HMGamepadStateHelpers", "HMProfile" }) if (assembly.GetType("HIDMaestro." + forbidden) != null) throw new InvalidDataException();
    if ((ushort)HMAxis.X != 0x130 || (ushort)HMAxis.Y != 0x131 || (ushort)HMAxis.Rx != 0x133 || (ushort)HMAxis.Ry != 0x134 || (ushort)HMAxis.Vx != 0x140 || (ushort)HMAxis.Vy != 0x141 || (uint)HMButton.Guide != 1u << 10 || (byte)HMHat.None != 0 || (byte)HMHat.NorthWest != 8) throw new InvalidDataException();
    int count = 0, errors = 0, adversarial = 0; JsonElement? first = null;
    foreach (var line in File.ReadLines(args[0]))
    {
        if (++count > 4096 || line.Length > 2048) throw new InvalidDataException();
        using var document = JsonDocument.Parse(line); var frame = document.RootElement;
        var report = Convert.FromHexString(StateAdapter.Report(frame));
        string? rejected = report[0] != 0 || report[1] != 20 ? "invalid-header" : (BinaryPrimitives.ReadUInt16LittleEndian(report.AsSpan(2)) & 0x0800) != 0 ? "reserved-button-bit" : report.AsSpan(14).IndexOfAnyExcept((byte)0) >= 0 ? "reserved-bytes" : null;
        var dpad = report[2] & 15;
        if (rejected == null && dpad is not (0 or 1 or 9 or 8 or 10 or 2 or 6 or 4 or 5)) rejected = "unsupported-dpad";
        if (rejected != null)
        {
            StateAdapter.Exact(frame, "version", "reportHex", "error");
            if (StateAdapter.Integer(frame.GetProperty("version")) != 1 || frame.GetProperty("error").GetString() != rejected) throw new InvalidDataException();
            errors++; continue;
        }
        var state = StateAdapter.Adapt(frame); first ??= frame.Clone();
        if (state.Axes == null || state.HatDegrees != null || state.HatHundredths != null || state.HatRaw != null) throw new InvalidDataException();
        for (var axis = 0; axis < 4; axis++)
        {
            var raw = BinaryPrimitives.ReadInt16LittleEndian(report.AsSpan(6 + axis * 2));
            var fraction = (float)raw / (raw < 0 ? 65536f : 65534f); var expected = 0.5f + fraction;
            if (axis is 1 or 3) expected = 1f - expected;
            if (BitConverter.SingleToUInt32Bits(state.Axes[StateAdapter.Axes[axis]]) != BitConverter.SingleToUInt32Bits(expected)) throw new InvalidDataException();
        }
        if (state.Axes[HMAxis.Vx] != report[4] / 255f || state.Axes[HMAxis.Vy] != report[5] / 255f) throw new InvalidDataException();
        HMButton buttons = HMButton.None; var sourceButtons = BinaryPrimitives.ReadUInt16LittleEndian(report.AsSpan(2));
        foreach (var (bit, target) in new (int, HMButton)[] { (12,HMButton.A),(13,HMButton.B),(14,HMButton.X),(15,HMButton.Y),(8,HMButton.LeftBumper),(9,HMButton.RightBumper),(5,HMButton.Back),(4,HMButton.Start),(6,HMButton.LeftStick),(7,HMButton.RightStick),(10,HMButton.Guide) }) if ((sourceButtons & (1 << bit)) != 0) buttons |= target;
        var hat = dpad switch { 0 => HMHat.None, 1 => HMHat.North, 9 => HMHat.NorthEast, 8 => HMHat.East, 10 => HMHat.SouthEast, 2 => HMHat.South, 6 => HMHat.SouthWest, 4 => HMHat.West, 5 => HMHat.NorthWest, _ => throw new InvalidDataException() };
        if (state.Buttons != buttons || state.Hat != hat) throw new InvalidDataException();
    }
    if (count < 34 || errors < 3 || first == null) throw new InvalidDataException();
    var valid = first.Value.GetRawText();
    var mutations = new List<JsonObject>();
    JsonObject Changed() => JsonNode.Parse(valid)!.AsObject();
    var extra = Changed(); extra["extra"] = true; mutations.Add(extra);
    var bits = Changed(); bits["axes"]![0]!["bits"] = 0x7fc00000u; mutations.Add(bits);
    var duplicate = Changed(); duplicate["axes"]![1]!["usage"] = (ushort)HMAxis.X; mutations.Add(duplicate);
    var buttonsBad = Changed(); buttonsBad["buttons"] = 0x80000000u; mutations.Add(buttonsBad);
    var hatBad = Changed(); hatBad["hat"] = 9; mutations.Add(hatBad);
    foreach (var mutation in mutations)
    {
        using var bad = JsonDocument.Parse(mutation.ToJsonString()); bool failed = false;
        try { StateAdapter.Adapt(bad.RootElement); } catch (InvalidDataException) { failed = true; }
        if (!failed) throw new InvalidDataException(); adversarial++;
    }
    var duplicatedJson = valid.Replace("\"version\":1", "\"version\":1,\"version\":1");
    using (var bad = JsonDocument.Parse(duplicatedJson)) { bool failed = false; try { StateAdapter.Adapt(bad.RootElement); } catch (InvalidDataException) { failed = true; } if (!failed) throw new InvalidDataException(); adversarial++; }
    Console.WriteLine(JsonSerializer.Serialize(new { version = 1, kind = "pinned-data-api-conformance", cases = count, rejectedReports = errors, adversarialCases = adversarial, officialSdkAssembly = false, sdkContextCompiled = false, sdkControllerCompiled = false, driverExecuted = false, gameplayVerified = false }));
    return 0;
}
catch { Console.Error.WriteLine("candidate_api_conformance_rejected"); return 1; }
