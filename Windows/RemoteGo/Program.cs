using System.IO;
using System.Drawing.Drawing2D;
using System.Reflection;
using System.Text.Json;
using SystemEvents = Microsoft.Win32.SystemEvents;
using SessionSwitchEventArgs = Microsoft.Win32.SessionSwitchEventArgs;
using SessionSwitchReason = Microsoft.Win32.SessionSwitchReason;

namespace RemoteGo;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        using var instance = new Mutex(true, @"Local\RemoteGo.Desktop", out var first);
        if (!first)
        {
            MessageBox.Show("Remote Go is already running. Open it from the taskbar notification area.", "Remote Go");
            return;
        }
        ApplicationConfiguration.Initialize();
        Application.Run(new Desk());
    }
}

internal sealed class Desk : Form
{
    private static readonly Color Canvas = Color.FromArgb(239, 241, 245), Ink = Color.FromArgb(27, 33, 47),
        Blue = Color.FromArgb(47, 95, 208);
    private readonly string config = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "RemoteGo", "settings.json");
    private readonly Settings settings;
    private readonly RawRemote raw = new();
    private readonly Controller controller;
    private readonly Dictionary<string, string> translations;
    private readonly ToolTip tips = new();
    private readonly NotifyIcon tray;
    private readonly Label message = new() { AutoSize = true, Padding = new(7) }, voiceStatus = new() { AutoSize = true };
    private readonly Label connection = new() { AutoSize = true, Padding = new(5) };
    private readonly Dictionary<ButtonId, Button> buttons = new();
    private readonly Panel picture = new() { Dock = DockStyle.Fill, BackColor = Color.FromArgb(225, 232, 246) };
    private readonly FlowLayoutPanel editor = new() { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown,
        WrapContents = false, AutoScroll = true, Padding = new(24), BackColor = Color.White };
    private readonly ComboBox preset = Dropdown(), app = Dropdown(), action = Dropdown(), voiceDevice = Dropdown();
    private readonly Label editorTitle = new() { AutoSize = true, Font = new("Segoe UI", 24, FontStyle.Bold) };
    private readonly TextBox ruleName = new() { Width = 310 };
    private readonly CheckBox enable = new() { AutoSize = true }, pointer = new() { AutoSize = true },
        holdVoice = new() { AutoSize = true };
    private readonly Button language = new(), choice = new(), voiceChoice = new(), doubleChoice = new();
    private readonly Image artwork;
    private ButtonId selected = ButtonId.Ok;
    private int connections;
    private bool updating;
    private string? voiceMessage;
    private string statusMessage = "按一下遥控器，查看 Windows 收到的按键";
    private enum RecordTarget { Mapping, Voice, DoubleTap }
    private RecordTarget? recording;
    private KeyMods recordedModifiers;

    internal Desk()
    {
        settings = Settings.Load(config);
        controller = new(settings);
        translations = JsonSerializer.Deserialize<Dictionary<string, string>>(Resource("RemoteGo.English.json")) ?? [];
        using var stream = Resource("RemoteGo.Remote.png");
        using var loadedArtwork = Image.FromStream(stream);
        artwork = new Bitmap(loadedArtwork);
        Icon = Icon.ExtractAssociatedIcon(Environment.ProcessPath!) ?? SystemIcons.Application;
        tray = new NotifyIcon { Icon = Icon, Visible = true, Text = "Remote Go" };
        tray.DoubleClick += (_, _) => Restore();
        Text = "Remote Go";
        MinimumSize = new(780, 620);
        ClientSize = new(950, 730);
        StartPosition = FormStartPosition.CenterScreen;
        Font = new("Segoe UI", 10);
        BackColor = Canvas;
        ForeColor = Ink;
        AutoScaleMode = AutoScaleMode.Dpi;
        KeyPreview = true;

        raw.Connection += count => { connections = count; RenderStatus(); if (count == 0) { controller.Reset(); SetToggles(); } };
        raw.Edge += controller.Input;
        controller.Button += (key, down) =>
        {
            if (buttons.TryGetValue(key, out var button)) button.ForeColor = down ? Color.ForestGreen : Ink;
            if (down) Report($"{T("最近按键")} · {T(key.Label)}");
        };
        controller.Status += Report;
        controller.VoiceStatus += value => { voiceMessage = value; RenderStatus(); };
        controller.PresetChanged += LoadMenus;
        controller.StateChanged += () => { SetToggles(); Save(); };
        enable.CheckedChanged += (_, _) => { if (!updating) controller.SetEnabled(enable.Checked); };
        pointer.CheckedChanged += (_, _) => { if (!updating) controller.SetPointer(pointer.Checked); };
        language.Click += (_, _) => { settings.English = !settings.English; BuildUI(); Save(); };
        preset.SelectedIndexChanged += (_, _) =>
        {
            if (updating || preset.SelectedItem is not Item item) return;
            controller.Reset();
            settings.ActiveId = item.Id;
            Save();
            SetToggles();
            RefreshEditor();
        };
        app.SelectedIndexChanged += (_, _) => { if (!updating) RefreshEditor(); };
        action.SelectedIndexChanged += (_, _) => { if (!updating && action.SelectedItem is Item item)
            SetRule(CurrentRule with { Action = item.Id, CodexOnly = false }); };
        ruleName.Validated += (_, _) =>
        {
            if (!updating && ruleName.Text.Trim() != CurrentRule.Name && ruleName.Text.Trim().Length > 0)
                SetRule(CurrentRule with { Name = ruleName.Text.Trim() });
        };
        choice.Click += (_, _) => Record(RecordTarget.Mapping);
        voiceChoice.Click += (_, _) => Record(RecordTarget.Voice);
        doubleChoice.Click += (_, _) => Record(RecordTarget.DoubleTap);
        holdVoice.CheckedChanged += (_, _) =>
        {
            if (updating) return;
            controller.Reset(); SetToggles(); settings.HoldToTalk = holdVoice.Checked; Save();
        };
        voiceDevice.DropDown += (_, _) => LoadAudioDevices();
        voiceDevice.SelectedIndexChanged += (_, _) =>
        {
            if (updating || voiceDevice.SelectedItem is not Item item) return;
            controller.Reset(); SetToggles(); settings.VoiceOutput = item.Id.Length == 0 ? null : item.Id; Save();
        };
        picture.Paint += (_, e) =>
        {
            var (x, y, scale) = PictureLayout();
            e.Graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
            e.Graphics.DrawImage(artwork, new RectangleF(x, y, 388 * scale, 1080 * scale));
        };
        picture.Resize += (_, _) => LayoutButtons();
        foreach (var key in RemoteButtons.Keys)
        {
            var button = new Button { FlatStyle = FlatStyle.Flat, BackColor = Color.Transparent, Text = key.Mark,
                AccessibleName = key.Label, TabStop = true, Margin = new(0) };
            button.FlatAppearance.BorderSize = 0;
            button.Click += (_, _) => { selected = key.Id; RefreshEditor(); };
            buttons[key.Id] = button;
            picture.Controls.Add(button);
        }
        Resize += (_, _) => { if (WindowState == FormWindowState.Minimized) Hide(); };
        Shown += (_, _) =>
        {
            if (!raw.Start(Handle)) Report("Windows 无法注册 HID 输入");
            controller.Start();
            SystemEvents.SessionSwitch += SessionChanged;
        };
        FormClosed += (_, _) =>
        {
            SystemEvents.SessionSwitch -= SessionChanged;
            controller.Dispose(); tray.Dispose(); artwork.Dispose(); tips.Dispose();
        };
        BuildUI();
    }

    private void SessionChanged(object sender, SessionSwitchEventArgs e)
    {
        if (e.Reason == SessionSwitchReason.SessionLock && IsHandleCreated)
            BeginInvoke(() => { controller.Reset(); SetToggles(); });
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == RawRemote.InputMessage) raw?.Receive(m.LParam);
        if (m.Msg == RawRemote.DeviceMessage) raw?.DeviceChanged(m.WParam, m.LParam);
        base.WndProc(ref m);
    }

    private void BuildUI()
    {
        // Reparent the persistent controls before disposing the old layout.
        var old = Controls.Count > 0 ? Controls[0] : null;
        Control[] persistent = [editorTitle, ruleName, action, choice, app, holdVoice, voiceChoice, doubleChoice, voiceDevice, voiceStatus];
        foreach (var control in persistent) control.Parent?.Controls.Remove(control);
        var trash = editor.Controls.Cast<Control>().ToList();
        editor.Controls.Clear();
        foreach (var control in trash) control.Dispose();
        var root = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 3 };
        root.RowStyles.Add(new(SizeType.Absolute, 64));
        root.RowStyles.Add(new(SizeType.Percent, 100));
        root.RowStyles.Add(new(SizeType.Absolute, 46));
        var bar = Row();
        bar.BackColor = Canvas;
        bar.Padding = new(12, 12, 12, 6);
        enable.Text = "Go";
        pointer.Text = T("飞鼠模式");
        language.Text = settings.English ? "简体中文" : "English";
        language.AutoSize = true;
        var title = new Label { Text = "Remote Go", Font = new("Segoe UI", 15, FontStyle.Bold), AutoSize = true,
            Margin = new(0, 2, 18, 0) };
        bar.Controls.AddRange([title, preset, enable, pointer, language, connection]);
        root.Controls.Add(bar, 0, 0);

        var content = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, Padding = new(10, 0, 10, 0) };
        content.ColumnStyles.Add(new(SizeType.Percent, 39));
        content.ColumnStyles.Add(new(SizeType.Percent, 61));
        content.Controls.Add(picture, 0, 0);
        content.Controls.Add(editor, 1, 0);
        root.Controls.Add(content, 0, 1);
        root.Controls.Add(message, 0, 2);

        var manage = Row();
        manage.Controls.AddRange([Make(B("保存副本", "Save a copy"), CopyPreset), Make(B("导入", "Import"), ImportPreset),
            Make(B("导出", "Export"), ExportPreset), Make(B("删除预设", "Delete preset"), DeletePreset)]);
        editor.Controls.Add(manage);
        editor.Controls.Add(Caption(T("按应用改键")));
        var apps = Row();
        apps.Controls.AddRange([app, Make(B("添加应用…", "Add app…"), AddApplication)]);
        editor.Controls.Add(apps);
        editor.Controls.Add(editorTitle);
        editor.Controls.Add(Caption(T("显示名称")));
        editor.Controls.Add(ruleName);
        editor.Controls.Add(Caption(T("按下时")));
        editor.Controls.Add(action);
        editor.Controls.Add(choice);
        editor.Controls.Add(Make(B("恢复默认映射", "Use default mapping"), ClearOverride));
        editor.Controls.Add(Caption(B("语音听写", "Dictation")));
        holdVoice.Text = B("按住快捷键说话", "Hold shortcut to talk");
        editor.Controls.Add(holdVoice);
        var voiceRow = Row();
        voiceRow.Controls.AddRange([voiceChoice, doubleChoice, Make(B("清除双击", "Clear double tap"), () =>
        {
            controller.Reset(); SetToggles(); settings.DoubleTapShortcut = null; Save(); RefreshEditor();
        })]);
        editor.Controls.Add(voiceRow);
        editor.Controls.Add(Caption(B("遥控器音频输出", "Remote audio output")));
        editor.Controls.Add(voiceDevice);
        editor.Controls.Add(voiceStatus);
        Controls.Add(root);
        if (old != null) { Controls.Remove(old); old.Dispose(); }
        var oldMenu = tray.ContextMenuStrip;
        tray.ContextMenuStrip = new ContextMenuStrip();
        tray.ContextMenuStrip.Items.Add(B("打开 Remote Go", "Open Remote Go"), null, (_, _) => Restore());
        tray.ContextMenuStrip.Items.Add(B("退出", "Quit"), null, (_, _) => Close());
        oldMenu?.Dispose();
        LoadMenus(); LoadAudioDevices(); SetToggles(); RenderStatus(); LayoutButtons();
    }

    private void Restore() { Show(); WindowState = FormWindowState.Normal; Activate(); }

    private void LoadMenus()
    {
        var selectedApp = ContextApp;
        updating = true;
        Fill(preset, settings.Presets.Select(item => new Item(item.Id, T(item.Name))), settings.ActiveId);
        var applications = Settings.Apps.Concat(settings.CustomApps).GroupBy(item => item.Id).Select(group => group.First());
        Fill(app, new[] { new Item("", B("默认映射", "Default mapping")) }
            .Concat(applications.Select(item => new Item(item.Id, T(item.Name)))), selectedApp ?? "");
        updating = false;
        RefreshEditor();
    }

    private void LoadAudioDevices()
    {
        AppEntry[] devices;
        try { devices = VoiceOutput.Devices(); }
        catch (Exception error) { Report(error.Message); return; }
        updating = true;
        var options = devices.Select(device => new Item(device.Id, device.Name)).ToList();
        if (settings.VoiceOutput is { } configured && options.All(item => item.Id != configured))
            options.Add(new(configured, B("已选设备未连接", "Selected device unavailable")));
        Fill(voiceDevice, new[] { new Item("", B("使用电脑麦克风", "Use PC microphone")) }.Concat(options),
            settings.VoiceOutput ?? "");
        updating = false;
    }

    private string? ContextApp => app.SelectedItem is Item { Id.Length: > 0 } item ? item.Id : null;
    private Rule CurrentRule => settings.Active.Get(selected, ContextApp);

    private void RefreshEditor()
    {
        updating = true;
        var rule = CurrentRule;
        editorTitle.Text = T(selected.Label);
        ruleName.Text = rule.Name;
        Fill(action, Actions.All.Select(name => new Item(name, name == Actions.Voice ? B("语音听写", "Dictation") : T(name))),
            rule.Action == Actions.VoiceLegacy ? Actions.Voice : rule.Action);
        choice.Visible = rule.Action == Actions.Key;
        choice.Text = rule.Stroke is { } shortcut ? Format(shortcut) : B("录入快捷键", "Record shortcut");
        voiceChoice.Text = B("长按 · ", "Hold · ") + Format(settings.VoiceShortcut);
        doubleChoice.Text = B("双击 · ", "Double tap · ") + (settings.DoubleTapShortcut is { } chord ? Format(chord) : B("关闭", "Off"));
        holdVoice.Checked = settings.HoldToTalk;
        foreach (var (id, button) in buttons)
        {
            button.AccessibleName = T(id.Label);
            button.BackColor = selected == id ? Color.FromArgb(190, 207, 246) : Color.Transparent;
            button.FlatAppearance.BorderColor = Blue;
            button.FlatAppearance.BorderSize = selected == id ? 2 : 0;
            tips.SetToolTip(button, $"{T(id.Label)} · {T(settings.Active.Get(id, ContextApp).Action)}");
        }
        updating = false;
    }

    private void SetRule(Rule rule)
    {
        controller.Reset();
        settings.Active.Set(rule, ContextApp);
        Save(); SetToggles(); RefreshEditor();
    }

    private void ClearOverride()
    {
        controller.Reset();
        if (ContextApp is { } key)
        {
            if (settings.Active.AppRules.TryGetValue(key, out var rules)) rules.RemoveAll(rule => rule.Id == selected);
        }
        else
        {
            var original = Settings.Defaults().Find(p => p.Id == settings.Active.Id);
            settings.Active.Rules.RemoveAll(rule => rule.Id == selected);
            if (original?.Rules.Find(rule => rule.Id == selected) is { } found) settings.Active.Rules.Add(found);
        }
        Save(); SetToggles(); RefreshEditor();
    }

    private void SetToggles()
    {
        updating = true;
        enable.Checked = settings.Enabled;
        pointer.Checked = controller.Pointer;
        pointer.Enabled = settings.Enabled;
        updating = false;
    }

    private void Report(string value) { statusMessage = value; RenderStatus(); }
    private void RenderStatus()
    {
        connection.Text = connections > 0 ? B("遥控器已连接", "Remote connected") : B("等待蓝牙遥控器", "Waiting for remote");
        message.Text = T(statusMessage);
        voiceStatus.Text = voiceMessage != null ? T(voiceMessage) : B("等待语音键", "Waiting for voice button");
        if (tray != null) tray.Text = settings.Enabled ? "Remote Go · Go" : "Remote Go · Paused";
    }

    private void Record(RecordTarget target)
    {
        controller.Reset();
        SetToggles();
        recording = target;
        recordedModifiers = 0;
        Report(B("请按下新的快捷键，Esc 取消", "Press a shortcut, Esc cancels"));
    }

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        if (recording is not { } target) return base.ProcessCmdKey(ref msg, keyData);
        var key = keyData & Keys.KeyCode;
        recordedModifiers |= Mods(keyData);
        if (key is Keys.LWin or Keys.RWin) { recordedModifiers |= KeyMods.Windows; return true; }
        if (key is Keys.ShiftKey or Keys.ControlKey or Keys.Menu) return true;
        if (key == Keys.Escape && recordedModifiers == 0) { recording = null; return true; }
        if ((int)key is < 1 or > 254) return true;
        var chord = new Shortcut((ushort)key, recordedModifiers);
        recording = null;
        if (target == RecordTarget.Mapping) SetRule(CurrentRule.WithShortcut(chord));
        else if (target == RecordTarget.Voice) settings.VoiceShortcut = chord;
        else settings.DoubleTapShortcut = chord;
        Save(); RefreshEditor(); Report(B("已保存快捷键", "Shortcut saved"));
        return true;
    }

    private static KeyMods Mods(Keys key) => ((key & Keys.Control) != 0 ? KeyMods.Control : 0) |
        ((key & Keys.Alt) != 0 ? KeyMods.Alt : 0) | ((key & Keys.Shift) != 0 ? KeyMods.Shift : 0);
    private static string Format(Shortcut key) => (key.Mods.HasFlag(KeyMods.Windows) ? "Win + " : "") +
        (key.Mods.HasFlag(KeyMods.Control) ? "Ctrl + " : "") + (key.Mods.HasFlag(KeyMods.Alt) ? "Alt + " : "") +
        (key.Mods.HasFlag(KeyMods.Shift) ? "Shift + " : "") + ((Keys)key.Key);

    private void CopyPreset() => AddPreset(settings.Active.Name + B(" 副本", " Copy"), settings.Active.Rules, settings.Active.AppRules);

    private void AddPreset(string name, List<Rule> rules, Dictionary<string, List<Rule>> appRules)
    {
        controller.Reset();
        var unique = name;
        for (var i = 2; settings.Presets.Any(item => item.Name == unique); i++) unique = $"{name} ({i})";
        var duplicate = new Preset(Guid.NewGuid().ToString(), unique, [.. rules],
            appRules.ToDictionary(pair => pair.Key, pair => pair.Value.ToList()));
        settings.Presets.Add(duplicate);
        settings.ActiveId = duplicate.Id;
        Save(); SetToggles(); LoadMenus();
    }

    private void DeletePreset()
    {
        var active = settings.Active;
        if (active.Id is "vibe-coding" or "video") return;
        if (MessageBox.Show(this, B("删除当前预设？", "Delete this preset?"), "Remote Go",
                MessageBoxButtons.OKCancel) != DialogResult.OK) return;
        controller.Reset();
        settings.Presets.Remove(active);
        settings.ActiveId = "vibe-coding";
        Save(); SetToggles(); LoadMenus();
    }

    private void ImportPreset()
    {
        using var dialog = new OpenFileDialog { Filter = "Remote Go preset|*.remote-go.json|JSON|*.json" };
        if (dialog.ShowDialog(this) != DialogResult.OK) return;
        try
        {
            var value = PresetFile.Read(dialog.FileName);
            var summary = $"{value.Name}\n\n{value.Rules.Count} {B("条默认映射", "default bindings")}, " +
                $"{value.AppRules.Count} {B("套应用映射", "app overrides")}";
            if (MessageBox.Show(this, summary, B("导入为新预设", "Import as new preset"),
                MessageBoxButtons.OKCancel) != DialogResult.OK) return;
            foreach (var entry in value.Applications)
                if (!Settings.Apps.Concat(settings.CustomApps).Any(item => item.Id == entry.Id)) settings.CustomApps.Add(entry);
            AddPreset(value.Name, value.Rules, value.AppRules);
        }
        catch (Exception error) { Report(error.Message); }
    }

    private void ExportPreset()
    {
        using var dialog = new SaveFileDialog { Filter = "Remote Go preset|*.remote-go.json", FileName = "preset.remote-go.json" };
        if (dialog.ShowDialog(this) != DialogResult.OK) return;
        try
        {
            var current = settings.Active;
            var apps = Settings.Apps.Concat(settings.CustomApps).Where(item => current.AppRules.ContainsKey(item.Id)).ToList();
            var value = new PresetFile(PresetFile.FileFormat, 1, current.Name, current.Rules, current.AppRules, apps);
            File.WriteAllText(dialog.FileName, JsonSerializer.Serialize(value, Settings.Json));
        }
        catch (Exception error) { Report(error.Message); }
    }

    private void AddApplication()
    {
        using var dialog = new OpenFileDialog { Filter = "Windows program|*.exe" };
        if (dialog.ShowDialog(this) != DialogResult.OK) return;
        var name = Path.GetFileNameWithoutExtension(dialog.FileName);
        var id = AgentApps.ApplicationId(name);
        if (id == null) { Report(B("无法识别该应用", "Application could not be identified")); return; }
        if (!Settings.Apps.Concat(settings.CustomApps).Any(item => item.Id == id))
            settings.CustomApps.Add(new(id, name));
        Save(); LoadMenus();
        app.SelectedItem = app.Items.Cast<Item>().FirstOrDefault(item => item.Id == id);
    }

    private void Save()
    {
        try { settings.Save(config); }
        catch (Exception error) { Report(error.Message); }
    }

    private (float X, float Y, float Scale) PictureLayout()
    {
        var scale = Math.Min(picture.ClientSize.Height / 1080f, picture.ClientSize.Width / 510f);
        return ((picture.ClientSize.Width - 456 * scale) / 2, (picture.ClientSize.Height - 1080 * scale) / 2, scale);
    }

    private void LayoutButtons()
    {
        var (x, y, scale) = PictureLayout();
        foreach (var key in RemoteButtons.Keys)
        {
            var button = buttons[key.Id];
            button.SetBounds((int)(x + (key.X - key.Width / 2) * scale), (int)(y + (key.Y - key.Height / 2) * scale),
                (int)(key.Width * scale), (int)(key.Height * scale));
            if (button.Width < 1 || button.Height < 1) continue;
            using var shape = new GraphicsPath();
            if (key.X < 388) shape.AddEllipse(0, 0, button.Width, button.Height);
            else shape.AddRectangle(new Rectangle(0, 0, button.Width, button.Height));
            var old = button.Region;
            button.Region = new Region(shape);
            old?.Dispose();
        }
        picture.Invalidate();
    }

    private static void Fill(ComboBox box, IEnumerable<Item> items, string id)
    {
        box.BeginUpdate();
        box.Items.Clear();
        box.Items.AddRange(items.Cast<object>().ToArray());
        box.SelectedItem = box.Items.Cast<Item>().FirstOrDefault(item => item.Id == id);
        if (box.SelectedIndex < 0 && box.Items.Count > 0) box.SelectedIndex = 0;
        box.EndUpdate();
    }

    private static Stream Resource(string name) => Assembly.GetExecutingAssembly().GetManifestResourceStream(name)!;
    private static FlowLayoutPanel Row() => new() { AutoSize = true, Dock = DockStyle.Top, WrapContents = true };
    private static ComboBox Dropdown() => new() { Width = 259, DropDownStyle = ComboBoxStyle.DropDownList };
    private static Button Make(string label, Action action)
    {
        var button = new Button { Text = label, AutoSize = true };
        button.Click += (_, _) => action();
        return button;
    }

    private static Label Caption(string label) => new() { Text = label, AutoSize = true, Margin = new(3, 12, 3, 2) };
    private string T(string label) => settings.English ? translations.GetValueOrDefault(label, label) : label;
    private string B(string chinese, string english) => settings.English ? english : chinese;
    private sealed record Item(string Id, string Label) { public override string ToString() => Label; }
}
