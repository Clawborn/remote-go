using System.IO;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows.Automation;

namespace RemoteGo;

internal sealed class AgentApps
{
    private static readonly string[][] ProcessNames =
        [["codex"], ["claude"], ["grok", "grokbot", "grok bot", "sand"], ["workbuddy"], ["doubaowork", "doubao work", "豆包工作"]];
    private static readonly string[] ComposerLabels =
        ["ask codex", "work with codex", "describe your", "prompt-textarea", "add a follow-up", "type a message",
         "write a message", "reply to claude", "message input", "写一条消息", "输入消息", "发送消息", "提示词", "prompt"];
    private static readonly string[] SessionLabels =
        ["sessions", "conversations", "threads", "chat history", "会话", "对话历史"];
    private readonly List<string> recent = [];

    internal static string? ForegroundApp => KeyFor(WindowProcess(GetForegroundWindow()));

    internal static AppEntry? ForegroundApplication()
    {
        var process = WindowProcess(GetForegroundWindow());
        var id = KeyFor(process);
        return id == null || process == null ? null : new(id, process);
    }

    internal string? Run(string action, string? foreground)
    {
        var codex = Settings.Apps[0].Id;
        var claude = Settings.Apps[1].Id;
        var grok = Settings.Apps[2].Id;
        return action switch
        {
            Actions.Codex or Actions.CodexChat => Activate(0),
            Actions.Claude or Actions.ClaudeChat => Activate(1),
            Actions.CycleAgents => Activate(foreground == codex ? 1 : 0),
            Actions.Previous when foreground == codex => Navigate(codex, -1, false),
            Actions.Next when foreground == codex => Navigate(codex, 1, false),
            Actions.GrokPrevious when foreground == grok => Navigate(grok, -1, false),
            Actions.GrokNext when foreground == grok => Navigate(grok, 1, false),
            Actions.Cycle when foreground == codex => Navigate(codex, 1, true),
            Actions.Sessions when foreground == codex || foreground == claude || foreground == grok => Navigate(foreground, 0, false),
            _ => null
        };
    }

    private static string? Activate(int index)
    {
        var alias = Settings.Apps[index].Id;
        var window = FindWindow(alias);
        if (window == 0)
        {
            var name = Settings.Apps[index].Name;
            using var catalog = new Process { StartInfo = new("powershell.exe")
            {
                CreateNoWindow = true, UseShellExecute = false,
                RedirectStandardOutput = true, ArgumentList =
                {
                    "-NoProfile", "-NonInteractive", "-Command",
                    $"Get-StartApps | Where-Object {{ $_.Name -eq '{name}' }} | Select-Object -First 1 -ExpandProperty AppID"
                }
            }};
            if (!catalog.Start()) return "找不到对应的 Windows 桌面应用";
            var pending = catalog.StandardOutput.ReadToEndAsync();
            if (!catalog.WaitForExit(4000))
            {
                catalog.Kill();
                return "读取 Windows 应用列表超时";
            }
            var appId = pending.GetAwaiter().GetResult().Trim();
            if (appId.Length == 0) return "找不到对应的 Windows 桌面应用";
            var start = new ProcessStartInfo("explorer.exe") { UseShellExecute = false };
            start.ArgumentList.Add(@"shell:AppsFolder\" + appId);
            Process.Start(start)?.Dispose();
            for (var i = 0; i < 15 && window == 0; i++)
            {
                Thread.Sleep(200);
                window = FindWindow(alias);
            }
        }
        if (window == 0) return "已请求打开应用";
        if (GetForegroundWindow() != window)
        {
            ShowWindowAsync(window, 9);
            if (!SetForegroundWindow(window)) return "Windows 未切换到目标窗口，请点一下任务栏图标";
        }
        FocusComposer(window);
        return null;
    }

    private string? Navigate(string origin, int direction, bool cycle)
    {
        var window = GetForegroundWindow();
        if (KeyFor(WindowProcess(window)) != origin) return null;
        var root = AutomationElement.FromHandle(window);
        var tree = Find(root, item => item.Current.ControlType != ControlType.Button &&
            (Matches(item.Current.Name, SessionLabels) || Matches(item.Current.AutomationId, SessionLabels)));
        if (tree == null) return "当前应用没有公开可识别的会话列表";

        var items = FindItems(tree);
        var current = items.FindIndex(item => item.TryGetCurrentPattern(SelectionItemPattern.Pattern, out var pattern)
            && ((SelectionItemPattern)pattern).Current.IsSelected);
        if (current < 0)
            current = items.FindIndex(item => item.Current.HasKeyboardFocus);
        if (items.Count == 0) return "会话列表为空";
        if (direction == 0)
        {
            items[Math.Max(0, current)].SetFocus();
            return null;
        }
        var target = Math.Clamp(current + direction, 0, items.Count - 1);
        if (cycle)
        {
            var names = items.Select(item => item.Current.Name).ToList();
            if (current >= 0 && !recent.Contains(names[current])) recent.Insert(0, names[current]);
            var choices = recent.Select(name => names.IndexOf(name)).Where(i => i >= 0).Distinct().Take(3).ToList();
            for (var i = 0; i < items.Count && choices.Count < 3; i++)
                if (!choices.Contains(i)) choices.Add(i);
            target = choices[(choices.IndexOf(current) + 1) % choices.Count];
        }
        if (GetForegroundWindow() != window) return null;
        var selected = items[target];
        if (selected.TryGetCurrentPattern(SelectionItemPattern.Pattern, out var selection))
            ((SelectionItemPattern)selection).Select();
        else if (selected.TryGetCurrentPattern(InvokePattern.Pattern, out var invoke))
            ((InvokePattern)invoke).Invoke();
        else return "当前会话不支持选择";
        if (!cycle && origin == Settings.Apps[0].Id)
        {
            var name = selected.Current.Name;
            recent.Remove(name);
            recent.Insert(0, name);
            if (recent.Count > 3) recent.RemoveAt(3);
        }
        Thread.Sleep(140);
        if (GetForegroundWindow() == window) FocusComposer(window);
        return null;
    }

    private static void FocusComposer(nint window)
    {
        var candidate = Find(AutomationElement.FromHandle(window), item =>
            item.Current.IsKeyboardFocusable && !item.Current.IsOffscreen &&
            (item.Current.ControlType == ControlType.Edit || item.Current.ControlType == ControlType.Document)
            && (Matches(item.Current.Name, ComposerLabels) || Matches(item.Current.AutomationId, ComposerLabels)));
        if (GetForegroundWindow() == window) candidate?.SetFocus();
    }

    private static bool Matches(string label, string[] phrases) => phrases.Any(phrase =>
        label.Contains(phrase, StringComparison.OrdinalIgnoreCase));

    private static AutomationElement? Find(AutomationElement root, Func<AutomationElement, bool> predicate) =>
        Descendants(root).FirstOrDefault(predicate);

    private static List<AutomationElement> FindItems(AutomationElement sidebar) => Descendants(sidebar)
        .Where(item => !item.Current.IsOffscreen && item.Current.IsEnabled
            && (item.Current.ControlType == ControlType.ListItem || item.Current.ControlType == ControlType.TreeItem)
            && (item.TryGetCurrentPattern(SelectionItemPattern.Pattern, out _) || item.TryGetCurrentPattern(InvokePattern.Pattern, out _)))
        .Take(150).ToList();

    private static IEnumerable<AutomationElement> Descendants(AutomationElement root)
    {
        var walker = TreeWalker.ControlViewWalker;
        var items = new Queue<AutomationElement>();
        items.Enqueue(root);
        var deadline = Environment.TickCount64 + 800;
        for (var inspected = 0; items.Count > 0 && inspected < 1000 && Environment.TickCount64 < deadline; inspected++)
        {
            var item = items.Dequeue();
            yield return item;
            for (var child = walker.GetFirstChild(item); child != null && items.Count < 1000 && Environment.TickCount64 < deadline;
                 child = walker.GetNextSibling(child))
                items.Enqueue(child);
        }
    }

    internal static string? ApplicationId(string process) => KeyFor(process);

    private static string? KeyFor(string? process)
    {
        if (process == null) return null;
        for (var i = 0; i < ProcessNames.Length; i++)
            if (ProcessNames[i].Contains(process, StringComparer.OrdinalIgnoreCase)) return Settings.Apps[i].Id;
        var key = "win." + string.Concat(process.ToLowerInvariant().Where(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '.'));
        return key == "win." ? null : key;
    }

    private static string? WindowProcess(nint window)
    {
        if (window == 0 || GetWindowThreadProcessId(window, out var pid) == 0) return null;
        try { using var process = Process.GetProcessById((int)pid); return process.ProcessName; }
        catch (Exception error) when (error is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception)
        { return null; }
    }

    private static nint FindWindow(string id)
    {
        var foreground = GetForegroundWindow();
        if (KeyFor(WindowProcess(foreground)) == id) return foreground;
        nint found = 0;
        EnumWindows((window, _) =>
        {
            if (!IsWindowVisible(window) || GetWindow(window, 4) != 0 || KeyFor(WindowProcess(window)) != id) return true;
            found = window;
            return false;
        }, 0);
        return found;
    }

    private delegate bool EnumWindowsCallback(nint window, nint context);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsCallback callback, nint context);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(nint window);
    [DllImport("user32.dll")] private static extern nint GetWindow(nint window, uint command);
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(nint window, out uint pid);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(nint window);
    [DllImport("user32.dll")] private static extern bool ShowWindowAsync(nint window, int command);
}

internal static class CodexUsage
{
    internal static async Task<string> Read()
    {
        var executable = (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator)
            .Select(directory => Path.Combine(directory.Trim('"'), "codex.exe")).FirstOrDefault(File.Exists);
        if (executable == null) throw new IOException("未找到 codex.exe，请确保 Codex CLI 已加入 PATH");
        using var process = Process.Start(new ProcessStartInfo(executable)
        {
            ArgumentList = { "app-server", "--listen", "stdio://" },
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true
        }) ?? throw new IOException("Codex CLI did not start.");
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(7));
        try
        {
            await process.StandardInput.WriteLineAsync("""{"id":0,"method":"initialize","params":{"clientInfo":{"name":"remote_go","title":"Remote Go","version":"1"}}}""");
            await process.StandardInput.FlushAsync(timeout.Token);
            while (await process.StandardOutput.ReadLineAsync(timeout.Token) is { } line)
            {
                if (line.Length > 262144) break;
                using var json = JsonDocument.Parse(line);
                if (!json.RootElement.TryGetProperty("id", out var id) || id.ValueKind != JsonValueKind.Number) continue;
                if (id.GetInt32() == 0)
                {
                    await process.StandardInput.WriteLineAsync("""{"method":"initialized"}""");
                    await process.StandardInput.WriteLineAsync("""{"id":1,"method":"account/rateLimits/read"}""");
                    await process.StandardInput.FlushAsync(timeout.Token);
                }
                if (id.GetInt32() != 1) continue;
                var result = json.RootElement.GetProperty("result");
                var limits = result.TryGetProperty("rateLimitsByLimitId", out var group)
                    && group.ValueKind == JsonValueKind.Object && group.TryGetProperty("codex", out var codex)
                    ? codex : result.GetProperty("rateLimits");
                var periods = new List<string>();
                foreach (var key in new[] { "primary", "secondary" })
                {
                    if (!limits.TryGetProperty(key, out var value) || value.ValueKind != JsonValueKind.Object) continue;
                    var remain = Math.Round(Math.Clamp(100 - value.GetProperty("usedPercent").GetDouble(), 0, 100));
                    var reset = value.TryGetProperty("resetsAt", out var timestamp) && timestamp.TryGetInt64(out var epoch)
                        ? $" · {DateTimeOffset.FromUnixTimeSeconds(epoch).ToLocalTime():g}" : "";
                    periods.Add($"{remain}% remaining{reset}");
                }
                if (periods.Count > 0) return string.Join("  /  ", periods);
                break;
            }
            throw new IOException("Codex 用量暂不可用");
        }
        finally { if (!process.HasExited) process.Kill(); }
    }
}
