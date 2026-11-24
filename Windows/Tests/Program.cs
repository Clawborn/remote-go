using System.Buffers.Binary;
using System.Text.Json;
using RemoteGo;

static void Check(bool condition, string test)
{
    if (!condition) throw new InvalidOperationException(test);
}

Check(RemoteButtons.DecodeReport([1,3,7])!.SequenceEqual([ButtonId.Up, ButtonId.Ok]), "Chromecast HID keys");
Check(RemoteButtons.DecodeReport([3,3])!.SequenceEqual([ButtonId.Up]), "duplicate selectors");
Check(RemoteButtons.DecodeReport([1,0,0,0]) is { Length: 0 }, "padded release report");
Check(RemoteButtons.DecodeReport([2,3,0]) is null, "unrelated report ID");
Check(RemoteButtons.DecodeReport([1,255,0]) is null, "invalid selector");
var settings = new Settings();
Check(settings.Active.Get(ButtonId.Ok).Stroke is { Key: 13 }, "Return mapping");
Check(settings.Active.Get(ButtonId.Plus, Settings.Apps[0].Id).Action == Actions.Previous, "Codex override");
Check(settings.Active.Get(ButtonId.Netflix).Action == Actions.Claude, "Agent launch");
Check(settings.Presets[1].Get(ButtonId.Netflix).Action == Actions.Captions, "Video captions");
Check(MacKeys.Translate(15, 1 << 20) == new Shortcut('R', KeyMods.Control), "cross-platform shortcut");

var path = Path.Combine(Path.GetTempPath(), "remote-go-tests-" + Guid.NewGuid().ToString("N"));
try
{
    var config = Path.Combine(path, "settings.json");
    var custom = settings.Active.Get(ButtonId.Up).WithShortcut(new('P', KeyMods.Windows | KeyMods.Shift));
    settings.Active.Set(custom, null);
    settings.Save(config);
    Check(Settings.Load(config).Active.Get(ButtonId.Up).Stroke == custom.Stroke, "settings round trip");
    var file = Path.Combine(path, "fixture.remote-go.json");
    File.WriteAllText(file, """
        {"format":"remote-go-preset","version":1,"name":"macOS fixture",
        "applications":[{"id":"com.openai.codex","name":"Codex"}],
        "rules":[{"id":{"page":12,"usage":65},"name":"确定","action":"键盘快捷键","keyCode":36,"modifiers":0,"codexOnly":false}],
        "appRules":{"com.openai.codex":[{"id":{"page":12,"usage":233},"name":"音量 +","action":"上一个 Codex 会话","keyCode":53,"modifiers":0,"codexOnly":false}]}}
        """);
    var imported = PresetFile.Read(file);
    Check(imported.Rules[0].Stroke is { Key: 13 }, "import macOS preset");
    Check(imported.AppRules["com.openai.codex"][0].Id == ButtonId.Plus, "import app override");
    File.WriteAllText(file, JsonSerializer.Serialize(imported with { Version = 2 }, Settings.Json));
    try { _ = PresetFile.Read(file); throw new InvalidOperationException("accepted unknown format version"); }
    catch (InvalidDataException) { }
}
finally { if (Directory.Exists(path)) Directory.Delete(path, true); }

var modern = VoiceFormat.Read([11,1,0,2,3,0,2])!;
Check(modern is { Modern: true, Codec: 2, FrameBytes: 2 }, "ATVV capabilities");
Check(VoiceFormat.Read([11,1,0,2,3,0,0]) == null, "reject zero ATVV frame size");
var decoder = new AtvvDecoder();
decoder.Reset(modern.Codec);
Check(decoder.Convert([0x77], modern).Length == 0, "hold partial ATVV frame");
var pcm = decoder.Convert([0x77], modern);
Check(pcm.Length == 8 && BinaryPrimitives.ReadInt16LittleEndian(pcm) == 11, "ATVV ADPCM samples");
decoder.Reset(1);
Check(decoder.Convert([0x77,0x77], modern).Length == 16, "8kHz to 16kHz audio");
Console.WriteLine("Remote Go checks passed: HID, profiles, macOS preset import, keyboard mappings and ATVV PCM.");
