using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

// 透明转发 MCP 标准输入输出；不修改消息，不返回允许/拒绝，也不保存请求正文。
internal static class McpConsentProxy
{
    private static readonly ConcurrentDictionary<string, Pending> pending = new ConcurrentDictionary<string, Pending>();
    private static long sequence;
    private static readonly string instance = Guid.NewGuid().ToString("N");
    private static string scriptPath, configPath;
    private static readonly object logGate = new object();
    private static readonly CancellationTokenSource lifetime = new CancellationTokenSource();
    private sealed class Pending { public readonly long Sequence = Interlocked.Increment(ref sequence); public readonly CancellationTokenSource Cancel = new CancellationTokenSource(); }
    private sealed class Framer
    {
        private readonly MemoryStream line = new MemoryStream();
        private readonly Action<string> observer;
        private bool oversized;
        public Framer(Action<string> action) { observer = action; }
        public void Feed(byte[] bytes, int count)
        {
            for (int i = 0; i < count; i++)
            {
                byte value = bytes[i];
                if (value == 10)
                {
                    if (!oversized && line.Length > 0)
                    {
                        try { observer(Encoding.UTF8.GetString(line.ToArray()).TrimEnd('\r')); } catch { }
                    }
                    line.SetLength(0); oversized = false;
                }
                else if (!oversized)
                {
                    // 工具结果可能含大图片，原样转发；只限制本机观察缓冲区。
                    if (line.Length >= 1048576) { oversized = true; line.SetLength(0); }
                    else line.WriteByte(value);
                }
            }
        }
    }
    private static void Log(string eventName)
    {
        try
        {
            string config = configPath;
            if (String.IsNullOrEmpty(config))
            {
                string home = Environment.GetEnvironmentVariable("CODEX_HOME");
                if (String.IsNullOrEmpty(home)) home = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex");
                config = Path.Combine(home, "ntfy-codex.json");
            }
            string log = Path.Combine(Path.GetDirectoryName(Path.GetFullPath(config)), "mcp-consent.log");
            lock (logGate) File.AppendAllText(log, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " " + eventName + Environment.NewLine, new UTF8Encoding(false));
        }
        catch { }
    }
    private static Dictionary<string, object> Parse(string line)
    {
        return new JavaScriptSerializer { MaxJsonLength = 1048576, RecursionLimit = 64 }.DeserializeObject(line) as Dictionary<string, object>;
    }
    private static string RequestKey(Dictionary<string, object> message)
    {
        object id;
        if (!message.TryGetValue("id", out id) || id == null) return null;
        // JSON 字符串 id 与数字 id 分开，避免相同显示内容互相取消。
        return id.GetType().FullName + ":" + new JavaScriptSerializer().Serialize(id);
    }
    private static void ServerMessage(string line)
    {
        Dictionary<string, object> message = Parse(line);
        object method;
        if (message == null || !message.TryGetValue("method", out method) || Convert.ToString(method) != "elicitation/create") return;
        string key = RequestKey(message);
        object rawParams;
        if (key == null || !message.TryGetValue("params", out rawParams) || !(rawParams is Dictionary<string, object>)) return;
        Pending request = new Pending();
        if (!pending.TryAdd(key, request)) { request.Cancel.Dispose(); return; }
        Log("elicitation-pending");
        // 请求先被转发给 Codex。快速自动答复或已点击的请求不再补发手机提醒。
        Task.Run(async delegate
        {
            using (CancellationTokenSource cancel = CancellationTokenSource.CreateLinkedTokenSource(request.Cancel.Token, lifetime.Token))
            {
                try
                {
                    await Task.Delay(1000, cancel.Token).ConfigureAwait(false);
                    cancel.Token.ThrowIfCancellationRequested();
                    Notify(Digest(instance + "|" + request.Sequence + "|" + key), cancel.Token);
                }
                catch (OperationCanceledException) { }
                catch { }
            }
        });
    }
    private static void ClientMessage(string line)
    {
        Dictionary<string, object> message = Parse(line);
        if (message == null) return;
        object method;
        if (message.TryGetValue("method", out method))
        {
            if (Convert.ToString(method) != "notifications/cancelled") return;
            // 调用被取消时，原生弹窗也会消失；其 id 可能与外层 tools/call id 不同。
            foreach (string cancelledKey in pending.Keys)
            {
                Pending cancelled;
                if (pending.TryRemove(cancelledKey, out cancelled)) { cancelled.Cancel.Cancel(); Log("elicitation-cancelled"); }
            }
            return;
        }
        else if (!message.ContainsKey("result") && !message.ContainsKey("error")) return;
        string key = RequestKey(message);
        Pending request;
        if (key != null && pending.TryRemove(key, out request)) { request.Cancel.Cancel(); Log("elicitation-answered"); }
    }
    private static async Task Pump(Stream input, Stream output, Framer observer)
    {
        byte[] bytes = new byte[16384];
        for (;;)
        {
            int count = await input.ReadAsync(bytes, 0, bytes.Length).ConfigureAwait(false);
            if (count == 0) break;
            await output.WriteAsync(bytes, 0, count).ConfigureAwait(false);
            await output.FlushAsync().ConfigureAwait(false);
            if (observer != null) observer.Feed(bytes, count);
        }
    }
    private static string Digest(string value)
    {
        using (SHA256 sha = SHA256.Create()) return BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(value))).Replace("-", "").ToLowerInvariant();
    }
    private static string Quote(string value)
    {
        if (value.Length > 0 && value.IndexOfAny(new char[] { ' ', '\t', '\n', '\v', '"' }) < 0) return value;
        StringBuilder result = new StringBuilder("\"");
        int slashes = 0;
        foreach (char character in value)
        {
            if (character == '\\') slashes++;
            else
            {
                if (character == '"') result.Append('\\', slashes * 2 + 1);
                else result.Append('\\', slashes);
                result.Append(character); slashes = 0;
            }
        }
        return result.Append('\\', slashes * 2).Append('"').ToString();
    }
    private static void Notify(string id, CancellationToken cancel)
    {
        if (!File.Exists(scriptPath) || cancel.IsCancellationRequested) return;
        string powerShell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
        ProcessStartInfo start = new ProcessStartInfo(powerShell);
        start.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Quote(scriptPath) + " -Event consent -ConsentId " + id;
        if (!String.IsNullOrEmpty(configPath)) start.Arguments += " -ConfigPath " + Quote(configPath);
        start.UseShellExecute = false; start.CreateNoWindow = true;
        start.RedirectStandardInput = true; start.RedirectStandardOutput = true; start.RedirectStandardError = true;
        start.EnvironmentVariables["PSModulePath"] = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "WindowsPowerShell", "v1.0", "Modules");
        using (Process process = Process.Start(start))
        {
            Log("notify-launched");
            process.StandardInput.Close();
            process.StandardOutput.ReadToEndAsync(); process.StandardError.ReadToEndAsync();
            using (cancel.Register(delegate { try { if (!process.HasExited) process.Kill(); } catch { } }))
            {
                if (!process.WaitForExit(12000)) { try { process.Kill(); } catch { } }
            }
        }
    }
    private static int Run(string[] args)
    {
        int index = 0;
        scriptPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "codex-ntfy-notify.ps1");
        configPath = "";
        while (index < args.Length && args[index] != "--")
        {
            string option = args[index++];
            if (index >= args.Length) throw new ArgumentException();
            string value = args[index++];
            if (option == "--notify-script") scriptPath = value;
            else if (option == "--config") configPath = value;
            else throw new ArgumentException();
        }
        if (index >= args.Length || ++index >= args.Length) throw new ArgumentException();
        string child = args[index++];
        if (String.Equals(Path.GetFullPath(child), Path.GetFullPath(Environment.GetCommandLineArgs()[0]), StringComparison.OrdinalIgnoreCase)) throw new ArgumentException();
        Log("relay-started");
        List<string> childArgs = new List<string>();
        for (; index < args.Length; index++) childArgs.Add(Quote(args[index]));
        ProcessStartInfo start = new ProcessStartInfo(child, String.Join(" ", childArgs));
        start.UseShellExecute = false; start.CreateNoWindow = true;
        start.RedirectStandardInput = true; start.RedirectStandardOutput = true; start.RedirectStandardError = true;
        using (Process process = Process.Start(start))
        {
            Task inbound = Task.Run(async delegate
            {
                try { await Pump(Console.OpenStandardInput(), process.StandardInput.BaseStream, new Framer(ClientMessage)).ConfigureAwait(false); }
                catch { }
                try { process.StandardInput.Close(); } catch { }
            });
            Task outbound = Pump(process.StandardOutput.BaseStream, Console.OpenStandardOutput(), new Framer(ServerMessage));
            Task errors = Pump(process.StandardError.BaseStream, Console.OpenStandardError(), null);
            process.WaitForExit();
            lifetime.Cancel();
            foreach (Pending request in pending.Values) request.Cancel.Cancel();
            try { Task.WaitAll(new Task[] { outbound, errors }, 3000); } catch { }
            return process.ExitCode;
        }
    }
    private static int Main(string[] args)
    {
        try { return Run(args); }
        catch { Console.Error.WriteLine("Codex 手机提醒：MCP 授权提醒辅助程序启动失败，请重新安装通知工具。"); return 1; }
        finally { lifetime.Cancel(); }
    }
}