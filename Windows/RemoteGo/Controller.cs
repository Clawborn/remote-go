using System.Diagnostics;

namespace RemoteGo;

internal sealed class Controller : IDisposable
{
    private readonly Settings settings;
    private readonly Output output = new();
    private readonly VoiceOutput voiceOutput = new();
    private readonly VoiceInput voice = new();
    private readonly AgentApps apps = new();
    private readonly Dictionary<ButtonId, Press> presses = new();
    private readonly System.Windows.Forms.Timer timer = new() { Interval = 16 };
    private long lastActivity = Environment.TickCount64, lastVoiceTap, voiceLimit;
    private Shortcut? latchedShortcut;
    private bool agentBusy, usageBusy, disposed, hasRemoteAudio;
    internal bool Pointer { get; private set; }
    internal event Action<string>? Status;
    internal event Action<string>? VoiceStatus;
    internal event Action<ButtonId, bool>? Button;
    internal event Action? StateChanged;
    internal event Action? PresetChanged;

    private sealed class Press(long time, string? app)
    {
        internal readonly long Time = time;
        internal readonly string? App = app;
        internal bool Consumed;
        internal bool Deferred;
        internal bool PointerPress;
        internal Action? Release;
        internal Shortcut? Repeat;
        internal long NextRepeat;
    }

    internal Controller(Settings settings)
    {
        this.settings = settings;
        output.Failed += () => Status?.Invoke("Windows 拒绝向当前窗口发送按键");
        voice.Status += message => VoiceStatus?.Invoke(message);
        voice.Button += down => Input(ButtonId.Voice, down);
        voice.Interrupted += () => StopVoice(true);
        voice.Samples += bytes =>
        {
            if (bytes.Length == 0 || !voiceOutput.Active) return;
            voiceOutput.Receive(bytes);
            if (hasRemoteAudio) return;
            hasRemoteAudio = true;
            VoiceStatus?.Invoke("收到遥控器音频");
        };
        timer.Tick += (_, _) => Tick();
    }

    internal void Start()
    {
        voice.Start();
        timer.Start();
    }

    internal void SetEnabled(bool enabled)
    {
        if (settings.Enabled == enabled) return;
        settings.Enabled = enabled;
        lastActivity = Environment.TickCount64;
        if (!enabled) Reset();
        Status?.Invoke(enabled ? "Remote Go 已启动" : "Remote Go 已暂停");
        StateChanged?.Invoke();
    }

    internal void SetPointer(bool value)
    {
        if (value && !settings.Enabled) return;
        if (Pointer == value) return;
        Reset();
        Pointer = value;
        Status?.Invoke(value ? "飞鼠模式" : "飞鼠已退出");
        StateChanged?.Invoke();
    }

    internal void Input(ButtonId key, bool down)
    {
        Button?.Invoke(key, down);
        if (!down)
        {
            if (presses.Remove(key, out var press)) Finish(key, press);
            return;
        }
        if (disposed || presses.ContainsKey(key)) return;
        lastActivity = Environment.TickCount64;
        var state = new Press(lastActivity, AgentApps.ForegroundApp);
        presses[key] = state;
        if (key == ButtonId.Power)
        {
            SetEnabled(!settings.Enabled);
            presses[key] = state;
            return;
        }
        if (!settings.Enabled) return;
        if (Pointer && (key == ButtonId.Back || key == ButtonId.Ok || IsArrow(key) || key == ButtonId.Plus || key == ButtonId.Minus))
        {
            if (key == ButtonId.Back) SetPointer(false);
            else
            {
                state.PointerPress = true;
                state.NextRepeat = lastActivity + 270;
                if (key == ButtonId.Ok) { output.Click(true); state.Release = () => output.Click(false); }
                else if (key == ButtonId.Plus || key == ButtonId.Minus) output.Scroll(key == ButtonId.Plus ? 120 : -120);
                else MovePointer(key, 0);
            }
            return;
        }
        if (key != ButtonId.Voice && latchedShortcut != null) StopVoice(true);
        var rule = settings.Active.Get(key, state.App);
        if (key == ButtonId.Source || key == ButtonId.Home ||
            (key == ButtonId.Plus && state.App == Settings.Apps[0].Id))
        {
            state.Deferred = true;
            return;
        }
        if (IsVoice(rule) && key == ButtonId.Voice && latchedShortcut != null)
        {
            StopVoice(true);
            state.Consumed = true;
            return;
        }
        if (IsVoice(rule) && key == ButtonId.Voice && settings.DoubleTapShortcut != null)
        {
            state.Deferred = true;
            BeginVoiceAudio();
            return;
        }
        Activate(rule, state, hold: true);
    }

    private void Finish(ButtonId key, Press state)
    {
        state.Release?.Invoke();
        if (!settings.Enabled || !state.Deferred || state.Consumed)
        {
            if (key == ButtonId.Voice && latchedShortcut == null) StopVoice(false);
            return;
        }
        var rule = settings.Active.Get(key, state.App);
        if (key == ButtonId.Voice && IsVoice(rule) && settings.DoubleTapShortcut is { } chord)
        {
            var now = Environment.TickCount64;
            if (lastVoiceTap > 0 && state.Time - lastVoiceTap < 420)
            {
                lastVoiceTap = 0;
                latchedShortcut = chord;
                output.Tap(chord);
                BeginVoiceAudio();
            }
            else
            {
                lastVoiceTap = now;
                StopVoice(false);
            }
            return;
        }
        if (state.App == AgentApps.ForegroundApp || key == ButtonId.Source)
            Activate(rule, state, hold: false);
    }

    private void Activate(Rule rule, Press press, bool hold)
    {
        if (rule.CodexOnly && press.App != Settings.Apps[0].Id &&
            !(rule.Id == ButtonId.Ok && press.App == Settings.Apps[1].Id)) return;
        if (rule.Stroke is { } shortcut)
        {
            if (hold)
            {
                press.Release = output.Press(shortcut);
                press.Repeat = shortcut;
                press.NextRepeat = Environment.TickCount64 + 250 * (SystemInformation.KeyboardDelay + 1);
            }
            else output.Tap(shortcut);
            return;
        }
        switch (rule.Action)
        {
            case Actions.Voice or Actions.VoiceLegacy:
                if (settings.HoldToTalk && hold) press.Release = output.Press(settings.VoiceShortcut);
                else output.Tap(settings.VoiceShortcut);
                if (rule.Id == ButtonId.Voice) BeginVoiceAudio();
                break;
            case Actions.SwitchApps:
                if (Pointer) SetPointer(false);
                output.Tap(new(0x09, KeyMods.Windows));
                break;
            case Actions.Pointer:
                SetPointer(!Pointer);
                break;
            case Actions.YouTube:
                Open("https://www.youtube.com/");
                break;
            case Actions.Netflix:
                Open("https://www.netflix.com/browse");
                break;
            case Actions.Codex or Actions.Claude or Actions.CodexChat or Actions.ClaudeChat or Actions.CycleAgents
                or Actions.Sessions or Actions.Cycle or Actions.Previous or Actions.Next or Actions.GrokNext or Actions.GrokPrevious:
                ExecuteAgentAction(rule.Action, press.App);
                break;
        }
    }

    private void Tick()
    {
        var now = Environment.TickCount64;
        if (!settings.Enabled) return;
        if (now - lastActivity >= 30 * 60 * 1000 && presses.Count == 0 && latchedShortcut == null)
        {
            SetEnabled(false);
            return;
        }
        if (voiceLimit > 0 && now >= voiceLimit)
        {
            if (presses.TryGetValue(ButtonId.Voice, out var held))
            {
                held.Release?.Invoke();
                held.Release = null;
            }
            StopVoice(true);
            VoiceStatus?.Invoke("已达 30 分钟听写上限");
        }
        foreach (var (key, press) in presses.ToArray())
        {
            if (press.PointerPress)
            {
                if (IsArrow(key)) MovePointer(key, now - press.Time);
                else if (key != ButtonId.Ok && now >= press.NextRepeat)
                {
                    output.Scroll(key == ButtonId.Plus ? 120 : -120);
                    press.NextRepeat = now + 80;
                }
                continue;
            }
            if (press.Repeat is { } repeat && press.Release != null && now >= press.NextRepeat)
            {
                output.Repeat(repeat);
                press.NextRepeat = now + (int)(1000 / (2.5 + 27.5 * SystemInformation.KeyboardSpeed / 31));
            }
            if (!press.Deferred || press.Consumed) continue;
            var threshold = key == ButtonId.Home ? 500 : key == ButtonId.Voice ? 280 : 1000;
            if (now - press.Time < threshold) continue;
            press.Consumed = true;
            if (key == ButtonId.Source)
                SetPointer(!Pointer);
            else if (key == ButtonId.Home)
            {
                var next = settings.ActiveId == "video" ? "vibe-coding" : "video";
                Reset();
                settings.ActiveId = next;
                PresetChanged?.Invoke();
                StateChanged?.Invoke();
            }
            else if (key == ButtonId.Plus && AgentApps.ForegroundApp == press.App)
                ShowUsage();
            else if (key == ButtonId.Voice)
            {
                lastVoiceTap = 0;
                Activate(settings.Active.Get(key, press.App), press, hold: true);
            }
        }
    }

    private void BeginVoiceAudio()
    {
        if (voiceLimit == 0) voiceLimit = Environment.TickCount64 + 30 * 60 * 1000;
        if (settings.VoiceOutput == null || voiceOutput.Active) return;
        try
        {
            voiceOutput.Start(settings.VoiceOutput);
            voice.Capture(true);
            VoiceStatus?.Invoke("等待遥控器音频");
        }
        catch (Exception error) { VoiceStatus?.Invoke(error.Message); }
    }

    private void StopVoice(bool endLatch)
    {
        if (endLatch && latchedShortcut is { } chord) output.Tap(chord);
        latchedShortcut = null;
        voiceLimit = 0;
        hasRemoteAudio = false;
        voice.Capture(false);
        voiceOutput.Dispose();
    }

    private async void ExecuteAgentAction(string action, string? owner)
    {
        if (agentBusy) return;
        agentBusy = true;
        try
        {
            var report = await Task.Run(() => apps.Run(action, owner));
            if (!disposed && report != null) Status?.Invoke(report);
        }
        catch (Exception error) { if (!disposed) Status?.Invoke(error.Message); }
        finally { agentBusy = false; }
    }

    private async void ShowUsage()
    {
        if (usageBusy) return;
        usageBusy = true;
        try
        {
            var usage = await CodexUsage.Read();
            if (!disposed) Status?.Invoke(usage);
        }
        catch (Exception error) { if (!disposed) Status?.Invoke(error.Message); }
        finally { usageBusy = false; }
    }

    private void Open(string address)
    {
        try { Process.Start(new ProcessStartInfo(address) { UseShellExecute = true })?.Dispose(); }
        catch (Exception error) { Status?.Invoke(error.Message); }
    }

    private void MovePointer(ButtonId key, long heldFor)
    {
        var distance = 2 + (int)Math.Min(heldFor / 100, 10);
        output.MoveBy(key == ButtonId.Left ? -distance : key == ButtonId.Right ? distance : 0,
            key == ButtonId.Up ? -distance : key == ButtonId.Down ? distance : 0);
    }

    private static bool IsArrow(ButtonId key) => key == ButtonId.Up || key == ButtonId.Down || key == ButtonId.Left || key == ButtonId.Right;
    private static bool IsVoice(Rule rule) => rule.Action is Actions.Voice or Actions.VoiceLegacy;

    internal void Reset()
    {
        foreach (var press in presses.Values) press.Release?.Invoke();
        presses.Clear();
        lastVoiceTap = 0;
        StopVoice(true);
        Pointer = false;
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        timer.Dispose();
        Reset();
        voice.Dispose();
    }
}
