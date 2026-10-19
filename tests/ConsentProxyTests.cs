using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
internal static class ConsentProxyTests
{
    private static readonly JavaScriptSerializer json = new JavaScriptSerializer { MaxJsonLength = 8388608 };
    private static int checks;
    private static void Assert(bool value, string message) { if (!value) throw new Exception(message); checks++; }
    private static string Encode(object value) { return json.Serialize(value); }
    private static int Child()
    {
        Console.InputEncoding = new UTF8Encoding(false); Console.OutputEncoding = new UTF8Encoding(false);
        Console.Error.WriteLine("fake-server-diagnostic");
        string line;
        while ((line = Console.ReadLine()) != null)
        {
            Dictionary<string, object> message = json.DeserializeObject(line) as Dictionary<string, object>;
            object rawMethod; string method = message.TryGetValue("method", out rawMethod) ? Convert.ToString(rawMethod) : "";
            if (method == "test/exit") return 7;
            if (method == "test/emit")
            {
                Dictionary<string, object> p = message["params"] as Dictionary<string, object>;
                string payload = Convert.ToString(p["payload"]);
                if (p.ContainsKey("fragment"))
                {
                    byte[] bytes = Encoding.UTF8.GetBytes(payload + "\n"); Stream output = Console.OpenStandardOutput();
                    for (int offset = 0; offset < bytes.Length; offset += 3) { output.Write(bytes, offset, Math.Min(3, bytes.Length - offset)); output.Flush(); }
                }
                else Console.WriteLine(payload);
            }
            else Console.WriteLine(Encode(new Dictionary<string, object> { { "method", "test/received" }, { "params", line } }));
        }
        return 0;
    }
    private static string Quote(string value) { return "\"" + value.Replace("\"", "\\\"") + "\""; }
    private static string Read(Process process)
    {
        Task<string> line = process.StandardOutput.ReadLineAsync();
        if (!line.Wait(5000)) throw new Exception("MCP forwarding timed out");
        return line.Result;
    }
    private static void Emit(Process p, string value, bool fragment)
    {
        Dictionary<string, object> args = new Dictionary<string, object> { { "payload", value } };
        if (fragment) args["fragment"] = true;
        p.StandardInput.WriteLine(Encode(new Dictionary<string, object> { { "method", "test/emit" }, { "params", args } })); p.StandardInput.Flush();
        Assert(Read(p) == value, "Server message was modified");
    }
    private static void Send(Process p, object value)
    {
        string line = Encode(value); p.StandardInput.WriteLine(line); p.StandardInput.Flush();
        Dictionary<string, object> echoed = json.DeserializeObject(Read(p)) as Dictionary<string, object>;
        Assert(Convert.ToString(echoed["params"]) == line, "Client response was modified");
    }
    private static object Response(object id, string action)
    { return new Dictionary<string, object> { { "jsonrpc", "2.0" }, { "id", id }, { "result", new Dictionary<string, object> { { "action", action } } } }; }
    private static string Request(object id)
    { return Encode(new Dictionary<string, object> { { "jsonrpc", "2.0" }, { "id", id }, { "method", "elicitation/create" }, { "params", new Dictionary<string, object> { { "message", "PRIVATE_REQUEST_BODY 不应发到手机或日志 🔔" }, { "requestedSchema", new Dictionary<string, object> { { "type", "object" } } } } } }); }
    private static string[] Markers(string marker)
    { try { return File.Exists(marker) ? File.ReadAllLines(marker) : new string[0]; } catch (IOException) { Thread.Sleep(30); return File.ReadAllLines(marker); } }
    private static void WaitCount(string marker, int count)
    {
        Stopwatch timer = Stopwatch.StartNew();
        while (Markers(marker).Length < count && timer.ElapsedMilliseconds < 5000) Thread.Sleep(50);
        Assert(Markers(marker).Length == count, "Unexpected notification count");
    }
    private static int Test(string proxy, string marker, string notify)
    {
        ProcessStartInfo start = new ProcessStartInfo(proxy, "--notify-script " + Quote(notify) + " --config " + Quote(marker) + " -- " + Quote(Assembly.GetExecutingAssembly().Location));
        start.UseShellExecute = false; start.CreateNoWindow = true; start.RedirectStandardInput = true; start.RedirectStandardOutput = true; start.RedirectStandardError = true;
        start.StandardOutputEncoding = Encoding.UTF8; start.StandardErrorEncoding = Encoding.UTF8;
        using (Process process = Process.Start(start))
        {
            process.StandardInput.AutoFlush = true;
            Task<string> errors = process.StandardError.ReadToEndAsync();
            Send(process, new Dictionary<string, object> { { "jsonrpc", "2.0" }, { "id", 1 }, { "method", "initialize" } });
            Emit(process, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"text\":\"中文与表情 🔔\"}}", true);
            Emit(process, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{}}", false);
            Thread.Sleep(1300); Assert(Markers(marker).Length == 0, "Ordinary tool call caused a notification");
            string request = Request(10); Emit(process, request, true); Emit(process, request, false);
            // 通知进程启动时，其他 MCP 消息仍须立即转发。
            Send(process, new Dictionary<string, object> { { "method", "ping" } });
            WaitCount(marker, 1); Assert(Markers(marker)[0].Length == 64, "Notification id was not a digest");
            Send(process, Response(10, "accept"));
            Emit(process, Request(11), false); Send(process, Response(11, "accept"));
            Thread.Sleep(1500); Assert(Markers(marker).Length == 1, "Already answered request was notified");
            Emit(process, Request(12), false);
            Send(process, new Dictionary<string, object> { { "method", "notifications/cancelled" }, { "params", new Dictionary<string, object> { { "requestId", 999 } } } });
            Thread.Sleep(1400); Assert(Markers(marker).Length == 1, "Cancelled request was notified");
            Emit(process, Request(13), false); Send(process, Response(13, "decline"));
            Thread.Sleep(1300); Assert(Markers(marker).Length == 1, "Declined request was notified");
            Emit(process, Request(14), false); Emit(process, Request("14"), false); WaitCount(marker, 3);
            Assert(Markers(marker)[1] != Markers(marker)[2], "String and numeric ids collided");
            Send(process, Response(14, "accept")); Send(process, Response("14", "accept"));
            Emit(process, Request(10), false); WaitCount(marker, 4); Send(process, Response(10, "accept"));
            Assert(Markers(marker)[0] != Markers(marker)[3], "Resolved request id reuse was treated as a duplicate");
            File.WriteAllText(marker + ".delay", "delay");
            Emit(process, Request(22), false);
            Stopwatch started = Stopwatch.StartNew();
            while (!File.Exists(marker + ".started") && started.ElapsedMilliseconds < 5000) Thread.Sleep(50);
            Assert(File.Exists(marker + ".started"), "Delayed sender did not start");
            Send(process, Response(22, "accept")); Thread.Sleep(2300);
            Assert(Markers(marker).Length == 4, "Answered request was notified during sender startup");
            File.Delete(marker + ".delay"); File.Delete(marker + ".started");
            string huge = Encode(new Dictionary<string, object> { { "jsonrpc", "2.0" }, { "id", 77 }, { "result", new String('x', 1100000) } });
            Emit(process, huge, false);
            Emit(process, Request(15), false);
            process.StandardInput.WriteLine("{\"method\":\"test/exit\"}"); process.StandardInput.Close();
            Assert(process.WaitForExit(5000) && process.ExitCode == 7, "Child exit status was not forwarded");
            Thread.Sleep(1300); Assert(Markers(marker).Length == 4, "Request was notified after server exit");
            Assert(errors.GetAwaiter().GetResult().Trim() == "fake-server-diagnostic", "stderr forwarding was modified");
            foreach (string id in Markers(marker)) Assert(System.Text.RegularExpressions.Regex.IsMatch(id, "^[a-f0-9]{64}$"), "Request body leaked into notification arguments");
        }
        Console.WriteLine("PASS: MCP consent relay " + checks + " checks"); return 0;
    }
    private static int Main(string[] args)
    {
        try { Console.InputEncoding = new UTF8Encoding(false); Console.OutputEncoding = new UTF8Encoding(false); return args.Length == 0 ? Child() : Test(args[0], args[1], args[2]); }
        catch (Exception error) { Console.Error.WriteLine(error.GetType().Name + ": " + error.Message); return 1; }
    }
}