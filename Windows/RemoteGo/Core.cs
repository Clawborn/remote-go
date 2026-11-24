using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace RemoteGo;

internal readonly record struct ButtonId(uint Page, uint Usage)
{
    internal static ButtonId Consumer(uint usage) => new(12, usage);
    internal static readonly ButtonId Up = Consumer(0x42), Down = Consumer(0x43),
        Left = Consumer(0x44), Right = Consumer(0x45), Ok = Consumer(0x41),
        Back = Consumer(0x224), Home = Consumer(0x223), Mute = Consumer(0xe2),
        Plus = Consumer(0xe9), Minus = Consumer(0xea), YouTube = Consumer(0x77),
        Netflix = Consumer(0x78), Power = Consumer(0x19e), Source = Consumer(0x89),
        Voice = new(0xff00, 1);

    internal string Label
    {
        get
        {
            var id = this;
            return RemoteButtons.Keys.FirstOrDefault(key => key.Id == id)?.Label ?? $"HID {Page:X}:{Usage:X}";
        }
    }
}

internal sealed record PhysicalKey(ButtonId Id, string Label, double X, double Y, double Width, double Height, string Mark = "");

internal static class RemoteButtons
{
    internal static readonly PhysicalKey[] Keys =
    [
        new(ButtonId.Up, "↑", 193, 65, 85, 85, "↑"),
        new(ButtonId.Left, "←", 89, 166, 85, 85, "←"),
        new(ButtonId.Ok, "确定", 193, 166, 106, 106),
        new(ButtonId.Right, "→", 297, 166, 85, 85, "→"),
        new(ButtonId.Down, "↓", 193, 266, 85, 85, "↓"),
        new(ButtonId.Back, "返回", 115, 377, 102, 102),
        new(ButtonId.Voice, "语音键", 270, 377, 102, 102),
        new(ButtonId.Home, "主页", 115, 511, 102, 102),
        new(ButtonId.Mute, "静音", 270, 511, 102, 102),
        new(ButtonId.YouTube, "YouTube", 115, 643, 102, 102),
        new(ButtonId.Netflix, "Netflix", 270, 643, 102, 102),
        new(ButtonId.Power, "电源", 113, 774, 66, 66),
        new(ButtonId.Source, "信源", 272, 774, 66, 66),
        new(ButtonId.Plus, "音量 +", 411, 256, 91, 71, "+"),
        new(ButtonId.Minus, "音量 −", 411, 338, 91, 71, "−")
    ];

    private static readonly uint[] Usages =
        [0, 0x19e, 0xcd, 0x42, 0x43, 0x44, 0x45, 0x41, 0xe2, 0x221, 0x223, 0x224, 0xe9, 0xea, 0x77, 0x78, 0x79, 0x89];

    internal static ButtonId[]? DecodeReport(ReadOnlySpan<byte> report)
    {
        if (report.Length > 2)
        {
            if (report[0] != 1) return null;
            report = report[1..];
        }
        if (report.Length < 2 || (report.Length > 2 && report[2..].ContainsAnyExcept((byte)0)))
            return null;
        var buttons = new List<ButtonId>(2);
        foreach (var selector in report[..2])
        {
            if (selector >= Usages.Length)
                return null;
            if (selector != 0)
            {
                var button = ButtonId.Consumer(Usages[selector]);
                if (!buttons.Contains(button)) buttons.Add(button);
            }
        }
        return [.. buttons];
    }
}

[Flags]
internal enum KeyMods { None = 0, Control = 1, Alt = 2, Shift = 4, Windows = 8 }
internal readonly record struct Shortcut(ushort Key, KeyMods Mods = KeyMods.None);

internal static class Actions
{
    internal const string None = "未设置动作", Key = "键盘快捷键", Voice = "Fn / Codex 听写",
        VoiceLegacy = "开始／结束遥控器听写", Codex = "打开 Codex", Claude = "打开 Claude",
        CodexChat = "打开 Codex 对话框", ClaudeChat = "打开 Claude 对话框", Sessions = "选择会话",
        Cycle = "轮换最近 3 个 Codex 会话", Next = "下一个 Codex 会话", Previous = "上一个 Codex 会话",
        GrokNext = "下一个 Grok Bot 会话", GrokPrevious = "上一个 Grok Bot 会话", CycleAgents = "轮换 Codex 和 Claude",
        SwitchApps = "切换应用", Pointer = "切换鼠标模式", Raise = "系统音量＋", Lower = "系统音量－",
        Mute = "系统静音", Play = "播放／暂停", Fullscreen = "播放器全屏", YouTube = "打开 YouTube",
        Netflix = "打开 Netflix", YouTubePlay = "YouTube 播放／暂停", Captions = "YouTube 字幕开关",
        Rewind = "YouTube 快退 10 秒", Forward = "YouTube 快进 10 秒", Preview = "打开／切换内置浏览器",
        Reload = "刷新网页预览", Annotate = "切换网页标注模式", Up = "向上", Down = "向下",
        Left = "向左", Right = "向右", PageUp = "向上翻页", PageDown = "向下翻页",
        Escape = "Esc / 返回", Suppress = "停用按键";

    internal static readonly string[] All = [None, Key, Voice, Up, Down, Left, Right, PageUp, PageDown, Escape,
        SwitchApps, Codex, Claude, CodexChat, ClaudeChat, Sessions, Cycle, Previous, Next, GrokPrevious, GrokNext,
        CycleAgents, Raise, Lower, Mute, Play, Fullscreen, YouTube, Netflix, YouTubePlay, Captions, Rewind, Forward,
        Pointer, Preview, Reload, Annotate, Suppress];

    internal static Shortcut? ShortcutFor(string action) => action switch
    {
        Up => new(0x26), Down => new(0x28), Left => new(0x25), Right => new(0x27),
        PageUp => new(0x21), PageDown => new(0x22), Escape => new(0x1b),
        Play => new(0x20), Fullscreen => new('F'), YouTubePlay => new('K'), Captions => new('C'),
        Rewind => new('J'), Forward => new('L'), Raise => new(0xaf), Lower => new(0xae), Mute => new(0xad),
        Preview => new('B', KeyMods.Control | KeyMods.Shift), Reload => new('R', KeyMods.Control),
        Annotate => new(0xbe, KeyMods.Control | KeyMods.Shift), _ => null
    };
}

internal sealed record Rule(ButtonId Id, string Name, string Action, ushort KeyCode = 53,
    ulong Modifiers = 0, bool CodexOnly = false, ushort? WindowsKeyCode = null, KeyMods? WindowsModifiers = null)
{
    internal Shortcut? Stroke => Action == Actions.Key
        ? WindowsKeyCode is ushort key ? new(key, WindowsModifiers ?? KeyMods.None) : MacKeys.Translate(KeyCode, Modifiers)
        : Actions.ShortcutFor(Action);

    internal Rule WithShortcut(Shortcut shortcut)
    {
        var (key, mods) = MacKeys.Reverse(shortcut);
        return this with { Action = Actions.Key, KeyCode = key, Modifiers = mods,
            WindowsKeyCode = shortcut.Key, WindowsModifiers = shortcut.Mods };
    }
}

internal static class MacKeys
{
    private const ulong Shift = 1 << 17, Ctrl = 1 << 18, Alt = 1 << 19, Cmd = 1 << 20;
    private static readonly Dictionary<ushort, ushort> Keys = new()
    {
        [0]='A', [1]='S', [2]='D', [3]='F', [4]='H', [5]='G', [6]='Z', [7]='X', [8]='C', [9]='V',
        [11]='B', [12]='Q', [13]='W', [14]='E', [15]='R', [16]='Y', [17]='T', [18]='1', [19]='2',
        [20]='3', [21]='4', [22]='6', [23]='5', [24]=0xbb, [25]='9', [26]='7', [27]=0xbd, [28]='8',
        [29]='0', [30]=0xdd, [31]='O', [32]='U', [33]=0xdb, [34]='I', [35]='P', [36]=0x0d, [37]='L',
        [38]='J', [39]=0xde, [40]='K', [41]=0xba, [42]=0xdc, [43]=0xbc, [44]=0xbf, [45]='N',
        [46]='M', [47]=0xbe, [48]=0x09, [49]=0x20, [50]=0xc0, [51]=0x08, [53]=0x1b,
        [96]=0x74, [97]=0x75, [98]=0x76, [99]=0x72, [100]=0x77, [101]=0x78, [103]=0x7a, [109]=0x79,
        [111]=0x7b, [115]=0x24, [116]=0x21, [117]=0x2e, [118]=0x73, [119]=0x23, [120]=0x71,
        [121]=0x22, [122]=0x70, [123]=0x25, [124]=0x27, [125]=0x28, [126]=0x26
    };

    internal static Shortcut? Translate(ushort key, ulong mods)
    {
        if (!Keys.TryGetValue(key, out var windows) || (mods & ~(Shift | Ctrl | Alt | Cmd)) != 0)
            return null;
        return new(windows, ((mods & (Ctrl | Cmd)) != 0 ? KeyMods.Control : 0)
            | ((mods & Alt) != 0 ? KeyMods.Alt : 0) | ((mods & Shift) != 0 ? KeyMods.Shift : 0));
    }

    internal static (ushort, ulong) Reverse(Shortcut shortcut)
    {
        var key = Keys.FirstOrDefault(pair => pair.Value == shortcut.Key);
        if (key.Value == 0 || shortcut.Mods.HasFlag(KeyMods.Windows))
            return (ushort.MaxValue, 0);
        var mods = shortcut.Mods;
        return (key.Key, (mods.HasFlag(KeyMods.Control) ? Cmd : 0)
            | (mods.HasFlag(KeyMods.Alt) ? Alt : 0) | (mods.HasFlag(KeyMods.Shift) ? Shift : 0));
    }
}

internal sealed record AppEntry(string Id, string Name);
internal sealed record Preset(string Id, string Name, List<Rule> Rules, Dictionary<string, List<Rule>> AppRules)
{
    internal Rule Get(ButtonId button, string? app = null) =>
        (app is not null && AppRules.TryGetValue(app, out var rules) ? rules.Find(rule => rule.Id == button) : null)
        ?? Rules.Find(rule => rule.Id == button) ?? new(button, button.Label, Actions.None);

    internal void Set(Rule rule, string? app)
    {
        var rules = Rules;
        if (app is not null && !AppRules.TryGetValue(app, out rules!))
            AppRules[app] = rules = [];
        rules.RemoveAll(old => old.Id == rule.Id);
        rules.Add(rule);
    }
}

internal sealed record PresetFile(string Format, int Version, string Name, List<Rule> Rules,
    Dictionary<string, List<Rule>> AppRules, List<AppEntry> Applications)
{
    internal const string FileFormat = "remote-go-preset";

    internal static PresetFile Read(string path)
    {
        using var file = File.OpenRead(path);
        if (file.Length > 256 * 1024) throw new InvalidDataException("Preset exceeds 256 KiB.");
        var value = JsonSerializer.Deserialize<PresetFile>(file, Settings.Json);
        if (value is null || value.Format != FileFormat || value.Version != 1 || string.IsNullOrWhiteSpace(value.Name)
            || value.AppRules is null || value.Applications is null || value.AppRules.Count > 128
            || !ValidRules(value.Rules) || !value.AppRules.All(pair => ValidId(pair.Key) && ValidRules(pair.Value))
            || value.Applications.Any(app => app is null || string.IsNullOrWhiteSpace(app.Name) || !value.AppRules.ContainsKey(app.Id))
            || value.Applications.Select(app => app.Id).Distinct().Count() != value.Applications.Count)
            throw new InvalidDataException("Invalid Remote Go preset.");
        return value;
    }

    private static bool ValidId(string text) => text.Length is > 0 and <= 255
        && text.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '.');
    private static bool ValidRules(List<Rule>? rules) => rules is not null && rules.Count <= 256
        && rules.All(rule => rule is not null && rule.Name is not null && rule.Id.Page <= 65535 && rule.Id.Usage <= 65535
            && (rule.Modifiers & ~0x1e0000UL) == 0 && (rule.WindowsModifiers.GetValueOrDefault() & ~(KeyMods)15) == 0
            && (!rule.WindowsKeyCode.HasValue || rule.WindowsKeyCode is > 0 and <= 254)
            && (rule.Action == Actions.VoiceLegacy || Actions.All.Contains(rule.Action)))
        && rules.Select(rule => rule.Id).Distinct().Count() == rules.Count;
}

internal sealed class Settings
{
    internal static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true, DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    public List<Preset> Presets { get; set; } = Defaults();
    public List<AppEntry> CustomApps { get; set; } = [];
    public string ActiveId { get; set; } = "vibe-coding";
    public bool Enabled { get; set; }
    public bool English { get; set; }
    public Shortcut VoiceShortcut { get; set; } = new('H', KeyMods.Windows);
    public bool HoldToTalk { get; set; }
    public Shortcut? DoubleTapShortcut { get; set; }
    public string? VoiceOutput { get; set; }

    internal static readonly AppEntry[] Apps =
    [
        new("com.openai.codex", "Codex"), new("com.anthropic.claudefordesktop", "Claude"),
        new("com.anysphere.sand", "Grok Bot"), new("com.tencent.workbuddy.mac", "WorkBuddy"),
        new("com.work.pc.doubao", "豆包工作")
    ];
    internal Preset Active => Presets.Find(preset => preset.Id == ActiveId) ?? Presets[0];

    internal static Settings Load(string path)
    {
        try
        {
            var settings = JsonSerializer.Deserialize<Settings>(File.ReadAllText(path), Json);
            return settings is not null && settings.Presets is { Count: > 0 } ? settings : new();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException) { return new(); }
    }

    internal void Save(string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temp = path + ".new";
        File.WriteAllText(temp, JsonSerializer.Serialize(this, Json));
        File.Move(temp, path, true);
    }

    internal static List<Preset> Defaults()
    {
        Rule Use(ButtonId id, string action) => new(id, id.Label, action);
        var arrows = new List<Rule> { Use(ButtonId.Up, Actions.Up), Use(ButtonId.Down, Actions.Down),
            Use(ButtonId.Left, Actions.Left), Use(ButtonId.Right, Actions.Right) };
        return
        [
            new("vibe-coding", "Agent Coding",
                [.. arrows, new Rule(ButtonId.Ok, ButtonId.Ok.Label, Actions.Key, 36),
                 Use(ButtonId.Voice, Actions.Voice), Use(ButtonId.Back, Actions.Sessions), Use(ButtonId.Home, Actions.Cycle),
                 Use(ButtonId.YouTube, Actions.Codex), Use(ButtonId.Netflix, Actions.Claude),
                 Use(ButtonId.Mute, Actions.Escape), Use(ButtonId.Source, Actions.SwitchApps)],
                new()
                {
                    [Apps[0].Id] = [Use(ButtonId.Plus, Actions.Previous), Use(ButtonId.Minus, Actions.Next)],
                    [Apps[2].Id] = [Use(ButtonId.Plus, Actions.GrokPrevious), Use(ButtonId.Minus, Actions.GrokNext)]
                }),
            new("video", "看视频",
                [Use(ButtonId.Up, Actions.Up), Use(ButtonId.Down, Actions.Down), Use(ButtonId.Left, Actions.Rewind),
                 Use(ButtonId.Right, Actions.Forward), Use(ButtonId.Ok, Actions.YouTubePlay), Use(ButtonId.Home, Actions.Fullscreen),
                 Use(ButtonId.Back, Actions.Escape), Use(ButtonId.YouTube, Actions.YouTube), Use(ButtonId.Netflix, Actions.Captions),
                 Use(ButtonId.Mute, Actions.Mute), Use(ButtonId.Plus, Actions.Raise), Use(ButtonId.Minus, Actions.Lower),
                 Use(ButtonId.Source, Actions.SwitchApps)], new())
        ];
    }
}
