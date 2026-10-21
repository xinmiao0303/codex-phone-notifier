using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

[assembly: AssemblyTitle("Codex 与 Claude Code 手机提醒")]
[assembly: AssemblyDescription("Codex 与 Claude Code 的 ntfy、微信 ClawBot 手机提醒配置工具")]
[assembly: AssemblyVersion("0.8.0.0")]
[assembly: AssemblyFileVersion("0.8.0.0")]

namespace CodexPhoneNotifier
{
    internal static class JsonValue
    {
        public static string Text(IDictionary<string, object> value, string key)
        { object item; return value != null && value.TryGetValue(key, out item) && item != null ? Convert.ToString(item) : ""; }
        public static bool Flag(IDictionary<string, object> value, string key)
        { object item; return value != null && value.TryGetValue(key, out item) && item != null && Convert.ToBoolean(item); }
        public static Dictionary<string, object> Object(IDictionary<string, object> value, string key)
        { object item; return value != null && value.TryGetValue(key, out item) ? item as Dictionary<string, object> : null; }
        public static IList List(IDictionary<string, object> value, string key)
        {
            object item;
            if (value == null || !value.TryGetValue(key, out item) || item == null) return new ArrayList();
            // PowerShell 把只有一项的数组写成单个对象，这里统一成列表。
            return item as IList ?? new ArrayList { item };
        }
    }

    // 一条可编辑的提醒：默认值来自发送脚本，界面只保存与默认不同的内容。
    internal sealed class ContentItem
    {
        public string Tool, Event, Label, Hint, TitleKey, BodyKey, DefaultTitle, DefaultBody, Title, Body;
        public readonly List<string> Placeholders = new List<string>();
        public string Display { get { return (Tool == "shared" ? "通用" : Tool == "codex" ? "Codex" : "Claude Code") + " · " + Label; } }
        public override string ToString() { return Display; }
        public static ContentItem From(string tool, Dictionary<string, object> data)
        {
            ContentItem item = new ContentItem { Tool = tool, Event = JsonValue.Text(data, "event"), Label = JsonValue.Text(data, "label"), Hint = JsonValue.Text(data, "hint"), TitleKey = JsonValue.Text(data, "titleKey"), BodyKey = JsonValue.Text(data, "bodyKey"), DefaultTitle = JsonValue.Text(data, "defaultTitle"), DefaultBody = ContentText.Lines(JsonValue.Text(data, "defaultBody")) };
            string title = JsonValue.Text(data, "title"), body = JsonValue.Text(data, "body");
            item.Title = String.IsNullOrWhiteSpace(title) ? item.DefaultTitle : title;
            item.Body = String.IsNullOrWhiteSpace(body) ? item.DefaultBody : ContentText.Lines(body);
            foreach (object name in JsonValue.List(data, "placeholders")) item.Placeholders.Add(Convert.ToString(name));
            return item;
        }
    }

    internal static class ContentText
    {
        private static readonly Regex Placeholder = new Regex(@"\{(电脑|时间|项目|原因|后台)\}");
        public static string Lines(string text) { return (text ?? "").Replace("\r\n", "\n").Replace("\n", "\r\n"); }
        public static bool Same(string a, string b) { return (a ?? "").Replace("\r\n", "\n").Trim() == (b ?? "").Replace("\r\n", "\n").Trim(); }
        public static Dictionary<string, string> SampleValues(string computer)
        {
            if (String.IsNullOrWhiteSpace(computer)) computer = Environment.GetEnvironmentVariable("COMPUTERNAME");
            if (String.IsNullOrWhiteSpace(computer)) computer = "这台电脑";
            // 与发送脚本的 -Preview 使用同一组示例值。
            return new Dictionary<string, string> { { "电脑", computer }, { "时间", DateTime.Now.ToString("yyyy-MM-dd    HH:mm:ss") }, { "项目", "示例项目" }, { "原因", "达到速率或用量限制" }, { "后台", "后台还有 1 个任务在运行。" } };
        }
        // 与发送脚本的 Format-NotifierText 规则一致：正文里占位符全为空的行整行省略。
        public static string Render(string template, Dictionary<string, string> values, bool title)
        {
            List<string> lines = new List<string>();
            foreach (string line in (template ?? "").Replace("\r\n", "\n").Split('\n'))
            {
                MatchCollection found = Placeholder.Matches(line);
                if (!title && found.Count > 0)
                {
                    bool any = false;
                    foreach (Match match in found) { string value; if (values.TryGetValue(match.Groups[1].Value, out value) && !String.IsNullOrEmpty(value)) any = true; }
                    if (!any) continue;
                }
                lines.Add(Placeholder.Replace(line, delegate(Match match) { string value; return values.TryGetValue(match.Groups[1].Value, out value) ? value : ""; }));
            }
            return title ? String.Join(" ", lines).Trim() : String.Join("\r\n", lines).Trim();
        }
    }

    internal sealed class DesktopBackend
    {
        public readonly string PayloadDirectory;
        public DesktopBackend()
        {
            string location = Assembly.GetExecutingAssembly().Location;
            string hash;
            using (SHA256 sha = SHA256.Create())
            using (FileStream file = File.OpenRead(location))
                hash = BitConverter.ToString(sha.ComputeHash(file)).Replace("-", "").Substring(0, 12);
            PayloadDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodexPhoneNotifier", "0.8.0-" + hash);
            Directory.CreateDirectory(PayloadDirectory);
            string[] files = { "install.ps1", "uninstall.ps1", "review-hooks.ps1", "scripts/common.ps1", "scripts/notify.ps1", "scripts/mcp-consent.ps1", "scripts/claude-common.ps1", "scripts/claude-notify.ps1", "claude-code/install.ps1", "claude-code/uninstall.ps1", "desktop/McpConsentProxy.cs", "desktop/desktop-backend.ps1", "desktop/assets/LUCIDE-LICENSE.txt", "desktop/assets/ICON-NOTICE.txt", "desktop/assets/LOBE-ICONS-LICENSE.txt", "LICENSE" };
            foreach (string relative in files)
            {
                string target = Path.Combine(PayloadDirectory, relative.Replace('/', Path.DirectorySeparatorChar));
                Directory.CreateDirectory(Path.GetDirectoryName(target));
                using (Stream input = Assembly.GetExecutingAssembly().GetManifestResourceStream("payload." + relative.Replace('/', '.')))
                {
                    if (input == null) throw new InvalidOperationException("软件资源不完整，请重新下载。");
                    using (MemoryStream bytes = new MemoryStream())
                    {
                        input.CopyTo(bytes);
                        byte[] content = bytes.ToArray();
                        if (!File.Exists(target) || !EqualBytes(File.ReadAllBytes(target), content)) File.WriteAllBytes(target, content);
                    }
                }
            }
        }
        private static bool EqualBytes(byte[] a, byte[] b)
        { if (a.Length != b.Length) return false; for (int i = 0; i < a.Length; i++) if (a[i] != b[i]) return false; return true; }
        public static string PowerShellPath()
        { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "WindowsPowerShell", "v1.0", "powershell.exe"); }
        public Dictionary<string, object> Run(Dictionary<string, object> request)
        {
            ProcessStartInfo start = new ProcessStartInfo(PowerShellPath());
            start.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + Path.Combine(PayloadDirectory, "desktop", "desktop-backend.ps1") + "\"";
            start.UseShellExecute = false; start.CreateNoWindow = true;
            start.RedirectStandardInput = true; start.RedirectStandardOutput = true; start.RedirectStandardError = true;
            start.StandardOutputEncoding = Encoding.UTF8; start.StandardErrorEncoding = Encoding.UTF8;
            // 固定为 Windows PowerShell 自带模块，防止从 PowerShell 7 启动时继承不兼容模块。
            start.EnvironmentVariables["PSModulePath"] = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "WindowsPowerShell", "v1.0", "Modules");
            using (Process process = Process.Start(start))
            {
                Task<string> stdout = process.StandardOutput.ReadToEndAsync();
                Task<string> stderr = process.StandardError.ReadToEndAsync();
                // Token 只经匿名标准输入传递，不写入参数、临时文件、日志或返回结果。
                string json = new JavaScriptSerializer().Serialize(request);
                byte[] input = Encoding.UTF8.GetBytes(json);
                process.StandardInput.BaseStream.Write(input, 0, input.Length);
                process.StandardInput.BaseStream.Flush(); process.StandardInput.Close();
                Array.Clear(input, 0, input.Length); json = null;
                // 一键部署会依次安装 Codex 与 Claude Code，给足时间。
                if (!process.WaitForExit(60000)) { process.Kill(); throw new InvalidOperationException("操作超过六十秒，请检查网络后重试。"); }
                string output = stdout.GetAwaiter().GetResult().Trim().TrimStart('﻿');
                stderr.GetAwaiter().GetResult(); // 不把未经清理的子进程错误或配置内容带到界面。
                if (process.ExitCode != 0 || String.IsNullOrWhiteSpace(output)) throw new InvalidOperationException("配置程序未正常完成，请重新打开软件或检查配置文件。");
                return new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(output);
            }
        }
        public void ReviewHooks()
        {
            ProcessStartInfo start = new ProcessStartInfo(PowerShellPath());
            start.Arguments = "-NoLogo -NoProfile -NoExit -ExecutionPolicy Bypass -File \"" + Path.Combine(PayloadDirectory, "review-hooks.ps1") + "\"";
            start.UseShellExecute = false; start.CreateNoWindow = false;
            start.EnvironmentVariables["PSModulePath"] = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "WindowsPowerShell", "v1.0", "Modules");
            Process.Start(start);
        }
    }

    internal sealed class MainForm : Form
    {
        private readonly DesktopBackend backend;
        private Icon taskbarIcon;
        private readonly bool preview;
        private readonly string directory, claudeDirectory;
        private bool installed, codexInstalled, claudeInstalled, codexDetected, claudeDetected, hasToken, busy, loading, dirty, keepConfig = true;
        private CheckBox ntfyEnabled, wechatEnabled, codexEnabled, claudeEnabled;
        private TextBox server, topic, token, result;
        private Label summary, tokenStatus, codexStatus, claudeStatus;
        private Button save, install, refresh, testNtfy, testWechat, removeNtfy, removeWechat, uninstall;
        private readonly List<Control> operationControls = new List<Control>();
        private readonly List<ContentItem> contentItems = new List<ContentItem>();
        private TabControl tabs;
        private TabPage contentPage;
        private ListBox contentList;
        private TextBox contentTitle, contentBody, contentPreview;
        private Label contentHeading, contentHint, contentPlaceholders;
        private Button contentReset, contentSend;
        private bool contentLoading;
        private string previewTool = "", previewEvent = "";
        private readonly Color ink = Color.FromArgb(32, 42, 62), blue = Color.FromArgb(41, 94, 218), muted = Color.FromArgb(94, 109, 132), good = Color.FromArgb(30, 123, 93), warn = Color.FromArgb(151, 90, 24), danger = Color.FromArgb(169, 48, 57);
        public MainForm(DesktopBackend service, bool isPreview) : this(service, isPreview, "") { }
        public MainForm(DesktopBackend service, bool isPreview, string previewPage)
        {
            backend = service; preview = isPreview;
            directory = Environment.GetEnvironmentVariable("CODEX_HOME");
            if (String.IsNullOrWhiteSpace(directory)) directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex");
            claudeDirectory = Environment.GetEnvironmentVariable("CLAUDE_CONFIG_DIR");
            if (String.IsNullOrWhiteSpace(claudeDirectory)) claudeDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude");
            Text = "Codex 与 Claude Code 手机提醒"; StartPosition = FormStartPosition.CenterScreen;
            Font = new Font("Microsoft YaHei UI", 9F); ForeColor = ink;
            BackColor = Color.FromArgb(243, 246, 251); AutoScaleMode = AutoScaleMode.Dpi;
            ClientSize = new Size(960, Math.Min(940, Screen.PrimaryScreen.WorkingArea.Height - 80)); MinimumSize = new Size(890, 700);
            using (Stream iconResource = Assembly.GetExecutingAssembly().GetManifestResourceStream("brand.icon"))
            using (Icon brand = new Icon(iconResource)) Icon = (Icon)brand.Clone();
            using (Stream taskbarResource = Assembly.GetExecutingAssembly().GetManifestResourceStream("brand.taskbar"))
                taskbarIcon = new Icon(taskbarResource, SystemInformation.IconSize);
            BuildInterface();
            Shown += async delegate { if (!preview) await RunOperation("status", "", false); };
            FormClosing += delegate(object sender, FormClosingEventArgs args)
            {
                if (busy) { args.Cancel = true; MessageBox.Show(this, "正在保存或发送，请等操作完成。", Text); }
                else if (dirty && !preview && MessageBox.Show(this, "还有未保存的更改。确定关闭窗口？", Text, MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) args.Cancel = true;
            };
            if (preview)
            {
                Dictionary<string, object> demo = new Dictionary<string, object> { { "installed", true }, { "codexInstalled", true }, { "claudeInstalled", true }, { "codexDetected", true }, { "claudeDetected", true }, { "codexEnabled", true }, { "claudeEnabled", true }, { "hasToken", true }, { "ntfyEnabled", false }, { "wechatEnabled", true }, { "server", "https://ntfy.sh" }, { "topic", "codex-demo-topic-for-preview" } };
                if (previewPage == "content")
                {
                    // 截图用：从不存在的临时目录读取默认内容，不读取或改动真实配置。
                    string empty = Path.Combine(Path.GetTempPath(), "codex-phone-preview-" + Guid.NewGuid().ToString("N"));
                    Dictionary<string, object> status = new DesktopBackend().Run(new Dictionary<string, object> { { "action", "status" }, { "directory", Path.Combine(empty, "codex") }, { "claudeDirectory", Path.Combine(empty, "claude") } });
                    demo["content"] = JsonValue.Object(JsonValue.Object(status, "data"), "content");
                }
                ApplyStatus(demo);
                result.Text = "Codex 与 Claude Code 提醒都已开启，通过微信聊天发送；ntfy 已暂停。主题和加密 Token 会保留，随时可以恢复。";
                if (previewPage == "content") { tabs.SelectedTab = contentPage; result.Text = "选择左侧的一条提醒，修改标题和正文，预览会立即更新。点击保存后自动提醒就会使用新内容。"; }
            }
        }
        [DllImport("user32.dll", CharSet = CharSet.Auto)]
        private static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr parameter, IntPtr value);
        protected override void OnHandleCreated(EventArgs args)
        {
            base.OnHandleCreated(args);
            // 大图标供任务栏和 Alt+Tab 使用；标题栏的小图标继续由 Form.Icon 提供。
            if (taskbarIcon != null) SendMessage(Handle, 0x0080, new IntPtr(1), taskbarIcon.Handle);
        }
        protected override void WndProc(ref Message message)
        {
            // 单独返回浅色大图标，避免 WinForms 更新窗口时恢复深色任务栏图标。
            if (message.Msg == 0x007F && message.WParam == new IntPtr(1) && taskbarIcon != null)
            { message.Result = taskbarIcon.Handle; return; }
            base.WndProc(ref message);
        }
        protected override void Dispose(bool disposing)
        {
            base.Dispose(disposing);
            if (disposing && taskbarIcon != null) { taskbarIcon.Dispose(); taskbarIcon = null; }
        }
        private Label LabelText(string text, int height)
        { return new Label { Text = text, AutoSize = false, Height = height, Width = 390, Margin = new Padding(0, 0, 0, 6), ForeColor = ink }; }
        private Button ButtonText(string text, int width, EventHandler handler)
        {
            Button button = new Button { Text = text, Width = width, Height = 34, FlatStyle = FlatStyle.Flat, BackColor = Color.White, Margin = new Padding(0, 0, 8, 6), Cursor = Cursors.Hand };
            button.FlatAppearance.BorderColor = Color.FromArgb(205, 214, 230);
            button.Click += handler; return button;
        }
        private void Track(Control control) { operationControls.Add(control); }
        private FlowLayoutPanel Card(TableLayoutPanel parent, int column, int padding)
        {
            Panel panel = new Panel { Dock = DockStyle.Fill, BackColor = Color.White, Padding = new Padding(padding), Margin = column == 0 ? new Padding(0, 0, 8, 0) : new Padding(8, 0, 0, 0) };
            FlowLayoutPanel flow = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoScroll = true };
            panel.Controls.Add(flow); parent.Controls.Add(panel, column, 0);
            flow.Layout += delegate { int width = Math.Max(260, flow.ClientSize.Width - SystemInformation.VerticalScrollBarWidth - 6); foreach (Control child in flow.Controls) if (child.Width != width) child.Width = width; };
            return flow;
        }
        private TableLayoutPanel TwoColumns()
        {
            TableLayoutPanel cards = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 1, ColumnCount = 2, Margin = new Padding(0) };
            cards.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50)); cards.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50)); cards.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            return cards;
        }
        private FlowLayoutPanel ButtonRow(params Button[] buttons)
        {
            FlowLayoutPanel row = new FlowLayoutPanel { Width = 390, Height = 40, Margin = new Padding(0), WrapContents = false };
            foreach (Button button in buttons) row.Controls.Add(button);
            return row;
        }
        private TextBox TextInput(bool password)
        {
            TextBox box = new TextBox { Width = 390, Height = 27, Margin = new Padding(0, 0, 0, 10), UseSystemPasswordChar = password, BorderStyle = BorderStyle.FixedSingle };
            box.TextChanged += delegate { Changed(); }; Track(box); return box;
        }
        private CheckBox Switch(string text)
        {
            CheckBox box = new CheckBox { Text = text, Height = 32, Width = 390, Font = new Font(Font.FontFamily, 12, FontStyle.Bold), Margin = new Padding(0, 0, 0, 2) };
            box.CheckedChanged += delegate { Changed(); }; Track(box); return box;
        }
        private void BuildInterface()
        {
            TableLayoutPanel root = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(24, 18, 24, 16), RowCount = 5, ColumnCount = 1 };
            root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            root.RowStyles.Add(new RowStyle(SizeType.Absolute, 66)); root.RowStyles.Add(new RowStyle(SizeType.Absolute, 36));
            root.RowStyles.Add(new RowStyle(SizeType.Absolute, 118)); root.RowStyles.Add(new RowStyle(SizeType.Percent, 100)); root.RowStyles.Add(new RowStyle(SizeType.Absolute, 118));
            Controls.Add(root);
            Panel heading = new Panel { Dock = DockStyle.Fill };
            heading.Controls.Add(new Label { Text = "Codex 与 Claude Code 手机提醒", Font = new Font(Font.FontFamily, 20, FontStyle.Bold), AutoSize = true, Location = new Point(0, 0), ForeColor = ink });
            heading.Controls.Add(new Label { Text = "任务结束、等待回答、确认计划或需要授权时，让手机提醒你。", AutoSize = true, Location = new Point(2, 41), ForeColor = muted });
            Label version = new Label { Text = "v0.8.0", AutoSize = true, Location = new Point(834, 10), ForeColor = muted };
            heading.Controls.Add(version); root.Controls.Add(heading, 0, 0);
            heading.Resize += delegate { version.Left = Math.Max(0, heading.ClientSize.Width - version.Width - 4); };
            summary = new Label { Text = "正在读取本机设置…", Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft, ForeColor = blue };
            root.Controls.Add(summary, 0, 1);
            // 提醒来源：两个开关只暂停或恢复对应工具的钩子，渠道设置两边共用。
            TableLayoutPanel sources = TwoColumns(); sources.Padding = new Padding(0, 0, 0, 10); root.Controls.Add(sources, 0, 2);
            FlowLayoutPanel c = Card(sources, 0, 14);
            codexEnabled = Switch("Codex 提醒"); c.Controls.Add(codexEnabled);
            c.Controls.Add(LabelText("任务完成、弹出选择题或文字输入、插件请求应用授权。", 20));
            codexStatus = LabelText("", 20); c.Controls.Add(codexStatus);
            FlowLayoutPanel a = Card(sources, 1, 14);
            claudeEnabled = Switch("Claude Code 提醒"); a.Controls.Add(claudeEnabled);
            a.Controls.Add(LabelText("任务完成、选择题、确认计划、工具授权、出错停止。", 20));
            claudeStatus = LabelText("", 20); a.Controls.Add(claudeStatus);
            foreach (FlowLayoutPanel source in new[] { c, a }) { source.AutoScroll = false; source.Parent.Padding = new Padding(16, 10, 16, 4); }
            tabs = new TabControl { Dock = DockStyle.Fill, Padding = new Point(18, 7) };
            TabPage notificationPage = new TabPage("通知渠道（两边共用）") { BackColor = BackColor, Padding = new Padding(12) };
            contentPage = new TabPage("提醒内容") { BackColor = BackColor, Padding = new Padding(12) };
            TabPage helpPage = new TabPage("安装与帮助") { BackColor = Color.White, Padding = new Padding(20) };
            tabs.TabPages.Add(notificationPage); tabs.TabPages.Add(contentPage); tabs.TabPages.Add(helpPage); root.Controls.Add(tabs, 0, 3);
            BuildContent(contentPage);
            codexEnabled.CheckedChanged += delegate { if (!loading) UpdateButtons(); };
            claudeEnabled.CheckedChanged += delegate { if (!loading) UpdateButtons(); };
            TableLayoutPanel cards = TwoColumns();
            notificationPage.Controls.Add(cards);
            FlowLayoutPanel n = Card(cards, 0, 18);
            ntfyEnabled = Switch("启用 ntfy 手机通知"); ntfyEnabled.Height = 34; ntfyEnabled.Margin = new Padding(0, 0, 0, 6); n.Controls.Add(ntfyEnabled);
            n.Controls.Add(LabelText("消息发到 ntfy App。手机订阅下面的主题，就能收到 Codex 与 Claude Code 的提醒。", 38));
            n.Controls.Add(LabelText("ntfy 服务器", 19)); server = TextInput(false); n.Controls.Add(server);
            n.Controls.Add(LabelText("订阅主题（手机和电脑要一致）", 19)); topic = TextInput(false); n.Controls.Add(topic);
            Button copyTopic = ButtonText("复制订阅主题", 160, delegate { if (!String.IsNullOrEmpty(topic.Text)) { Clipboard.SetText(topic.Text.Trim()); result.Text = "主题已复制，请在手机 ntfy 中订阅它。"; } });
            Button newTopic = ButtonText("生成新主题", 148, delegate
            {
                if (installed && !String.IsNullOrWhiteSpace(topic.Text) && MessageBox.Show(this, "更换主题后，手机需要订阅新的主题。继续生成？", Text, MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
                topic.Text = "codex-" + Guid.NewGuid().ToString("N").Substring(0, 24);
            }); Track(newTopic); n.Controls.Add(ButtonRow(copyTopic, newTopic));
            n.Controls.Add(LabelText("关闭开关会保留主题。订阅主题请自己保管，不要公开分享。", 38));
            testNtfy = ButtonText("保存并测试 ntfy", 320, async delegate { await RunOperation("test", "ntfy", true); }); Track(testNtfy); n.Controls.Add(testNtfy);
            removeNtfy = ButtonText("移除 ntfy 配置", 320, async delegate
            {
                if (Confirm("这会关闭 ntfy，并移除 Codex 与 Claude Code 两边的服务器、主题和认证设置。微信和钩子保留。继续？")) await RunOperation("remove-ntfy", "", false);
            }); Track(removeNtfy); n.Controls.Add(removeNtfy);
            FlowLayoutPanel w = Card(cards, 1, 18);
            wechatEnabled = Switch("启用微信聊天通知"); wechatEnabled.Height = 34; wechatEnabled.Margin = new Padding(0, 0, 0, 6); w.Controls.Add(wechatEnabled);
            w.Controls.Add(LabelText("通过 PushPlus ClawBot，发到你自己的微信机器人聊天。", 38));
            tokenStatus = LabelText("尚未保存 Token", 19); w.Controls.Add(tokenStatus);
            w.Controls.Add(LabelText("用户 Token（留空就保留已有密钥）", 19)); token = TextInput(true); w.Controls.Add(token);
            w.Controls.Add(LabelText("密钥只在本机加密保存，两边共用，不会显示已有 Token，也不会写进通知。", 38));
            Button pushplus = ButtonText("打开 PushPlus", 160, delegate { OpenUrl("https://www.pushplus.plus/push1.html"); });
            Button binding = ButtonText("绑定机器人教程", 148, delegate { OpenUrl("https://www.pushplus.plus/doc/channel/clawbot.html"); });
            w.Controls.Add(ButtonRow(pushplus, binding));
            Label requirement = LabelText("先在网站完成实名、扫码绑定并激活。每十条推送后，以及至少每二十四小时，要主动给机器人发一句话。两个工具都开时推送更多，请留意。", 60);
            requirement.ForeColor = warn; w.Controls.Add(requirement);
            testWechat = ButtonText("保存并测试微信", 320, async delegate { await RunOperation("test", "wechat", true); }); Track(testWechat); w.Controls.Add(testWechat);
            removeWechat = ButtonText("移除微信配置", 320, async delegate
            {
                if (Confirm("这会关闭微信，并删除 Codex 与 Claude Code 两边保存的加密 Token。ntfy 和钩子保留。继续？")) await RunOperation("remove-wechat", "", false);
            }); Track(removeWechat); w.Controls.Add(removeWechat);
            BuildHelp(helpPage);
            TableLayoutPanel footer = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 3, Padding = new Padding(0, 12, 0, 0) };
            footer.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            footer.RowStyles.Add(new RowStyle(SizeType.Absolute, 22)); footer.RowStyles.Add(new RowStyle(SizeType.Absolute, 40)); footer.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            footer.Controls.Add(new Label { Text = "更改开关后点击保存。打开尚未部署的提醒时，保存会自动部署它；测试按钮只发一条消息。", AutoSize = true, ForeColor = muted }, 0, 0);
            FlowLayoutPanel actions = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = false };
            save = ButtonText("保存设置", 140, async delegate { await RunOperation(installed ? "save" : "install", "", true); });
            save.BackColor = blue; save.ForeColor = Color.White; save.FlatAppearance.BorderColor = blue;
            install = ButtonText("一键部署 / 更新", 170, async delegate { await RunOperation("install", "", true); });
            refresh = ButtonText("重新读取", 110, async delegate { if (!dirty || Confirm("重新读取会放弃未保存的修改。继续？")) await RunOperation("status", "", false); });
            uninstall = ButtonText("一键卸载", 120, async delegate
            {
                DialogResult choice = MessageBox.Show(this, "卸载会移除 Codex 与 Claude Code 两边的提醒钩子和发送脚本，其他设置和钩子保留，原文件会先备份。\n\n是否保留主题和加密 Token，方便以后重装？\n\n是：保留　　否：一并删除　　取消：不卸载", Text, MessageBoxButtons.YesNoCancel, MessageBoxIcon.Question);
                if (choice == DialogResult.Cancel) return;
                keepConfig = choice == DialogResult.Yes;
                await RunOperation("uninstall", "", false);
            }); uninstall.ForeColor = danger;
            Track(save); Track(install); Track(refresh); Track(uninstall);
            actions.Controls.Add(save); actions.Controls.Add(install); actions.Controls.Add(refresh); actions.Controls.Add(uninstall); footer.Controls.Add(actions, 0, 1);
            result = new TextBox { Dock = DockStyle.Fill, Multiline = true, ReadOnly = true, BorderStyle = BorderStyle.None, BackColor = BackColor, ForeColor = ink, Text = "正在读取设置。", TabStop = false };
            footer.Controls.Add(result, 0, 2); root.Controls.Add(footer, 0, 4);
        }
        private void BuildContent(TabPage page)
        {
            TableLayoutPanel layout = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 1, ColumnCount = 2, Margin = new Padding(0) };
            layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 250)); layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            page.Controls.Add(layout);
            Panel left = new Panel { Dock = DockStyle.Fill, BackColor = Color.White, Padding = new Padding(10), Margin = new Padding(0, 0, 8, 0) };
            contentList = new ListBox { Dock = DockStyle.Fill, BorderStyle = BorderStyle.None, IntegralHeight = false, Font = new Font(Font.FontFamily, 10.5F) };
            contentList.SelectedIndexChanged += delegate { ShowContentItem(); };
            Track(contentList); left.Controls.Add(contentList); layout.Controls.Add(left, 0, 0);
            FlowLayoutPanel right = Card(layout, 1, 18);
            contentHeading = LabelText("请选择一条提醒", 30); contentHeading.Font = new Font(Font.FontFamily, 12, FontStyle.Bold); right.Controls.Add(contentHeading);
            contentHint = LabelText("", 36); contentHint.ForeColor = muted; right.Controls.Add(contentHint);
            right.Controls.Add(LabelText("标题", 19));
            contentTitle = new TextBox { Width = 390, Height = 27, Margin = new Padding(0, 0, 0, 10), BorderStyle = BorderStyle.FixedSingle, MaxLength = 60 };
            right.Controls.Add(contentTitle);
            right.Controls.Add(LabelText("正文（可以换行）", 19));
            contentBody = new TextBox { Width = 390, Height = 84, Margin = new Padding(0, 0, 0, 6), BorderStyle = BorderStyle.FixedSingle, Multiline = true, AcceptsReturn = true, ScrollBars = ScrollBars.Vertical, MaxLength = 1000 };
            right.Controls.Add(contentBody);
            contentPlaceholders = LabelText("", 36); contentPlaceholders.ForeColor = muted; right.Controls.Add(contentPlaceholders);
            right.Controls.Add(LabelText("手机上看到的样子（项目、原因等为示例值）", 19));
            contentPreview = new TextBox { Width = 390, Height = 92, Margin = new Padding(0, 0, 0, 10), BorderStyle = BorderStyle.FixedSingle, Multiline = true, ReadOnly = true, BackColor = Color.FromArgb(246, 248, 252), TabStop = false };
            right.Controls.Add(contentPreview);
            contentReset = ButtonText("恢复默认", 140, delegate
            {
                ContentItem item = contentList.SelectedItem as ContentItem;
                if (item == null) return;
                contentTitle.Text = item.DefaultTitle; contentBody.Text = item.DefaultBody;
            });
            contentSend = ButtonText("保存并发送预览", 168, async delegate
            {
                ContentItem item = contentList.SelectedItem as ContentItem;
                if (item == null) return;
                previewTool = item.Tool; previewEvent = item.Event;
                await RunOperation("preview", "", true);
            });
            Track(contentSend); right.Controls.Add(ButtonRow(contentReset, contentSend));
            contentTitle.TextChanged += delegate { EditContent(); };
            contentBody.TextChanged += delegate { EditContent(); };
        }
        private bool CanEdit(ContentItem item)
        {
            if (item.Tool == "codex") return codexInstalled || codexEnabled.Checked;
            if (item.Tool == "claude") return claudeInstalled || claudeEnabled.Checked;
            return true;
        }
        private void ShowContentItem()
        {
            ContentItem item = contentList.SelectedItem as ContentItem;
            contentLoading = true;
            if (item == null) { contentHeading.Text = "请选择一条提醒"; contentHint.Text = ""; contentTitle.Text = ""; contentBody.Text = ""; contentPlaceholders.Text = ""; }
            else
            {
                contentHeading.Text = item.Display;
                contentHint.Text = item.Hint;
                contentTitle.Text = item.Title; contentBody.Text = item.Body;
                List<string> names = new List<string>();
                foreach (string name in item.Placeholders) names.Add("{" + name + "}");
                contentPlaceholders.Text = "可用占位符：" + String.Join("  ", names.ToArray()) + "。标题和正文都能用；正文里某一行的占位符都为空时，整行会自动省略。";
            }
            contentLoading = false;
            UpdateContentPreview(); UpdateButtons();
        }
        private void EditContent()
        {
            if (contentLoading) return;
            ContentItem item = contentList.SelectedItem as ContentItem;
            if (item == null) return;
            item.Title = contentTitle.Text; item.Body = contentBody.Text;
            Changed(); UpdateContentPreview();
        }
        private void UpdateContentPreview()
        {
            ContentItem item = contentList.SelectedItem as ContentItem;
            if (item == null) { contentPreview.Text = ""; return; }
            // 文档截图不显示真实电脑名。
            Dictionary<string, string> values = ContentText.SampleValues(preview ? "我的电脑" : null);
            // 与发送脚本一样：替换后为空时退回默认内容。
            string title = ContentText.Render(item.Title, values, true);
            if (title.Length == 0) title = ContentText.Render(item.DefaultTitle, values, true);
            string body = ContentText.Render(item.Body, values, false);
            if (body.Length == 0) body = ContentText.Render(item.DefaultBody, values, false);
            contentPreview.Text = title + "\r\n\r\n" + body;
        }
        private void OpenFile(string path, string missing)
        { if (File.Exists(path)) Process.Start(new ProcessStartInfo("notepad.exe", "\"" + path + "\"") { UseShellExecute = true }); else result.Text = missing; }
        private void OpenFolder(string path)
        { if (Directory.Exists(path)) Process.Start(new ProcessStartInfo("explorer.exe", "\"" + path + "\"") { UseShellExecute = true }); else result.Text = "部署后会自动创建配置目录。"; }
        private void BuildHelp(TabPage page)
        {
            FlowLayoutPanel flow = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoScroll = true };
            page.Controls.Add(flow);
            Label title = LabelText("第一次使用，按这四步完成", 32); title.Font = new Font(Font.FontFamily, 14, FontStyle.Bold); title.Width = 810; flow.Controls.Add(title);
            Label steps = LabelText("1. 打开需要的提醒来源，填写通知渠道，点击“一键部署 / 更新”。\n\n2. Codex：点击下面的“打开 Codex 钩子审查”，检查本工具的命令后再信任，然后完整退出并重新打开 Codex。\n\n3. Claude Code：不需要审查，新开一个会话即生效（终端版需先信任所在文件夹）。\n\n4. 测试手机，再让 Codex 或 Claude Code 完成一次任务、弹出一道问题。", 190); steps.Width = 810; flow.Controls.Add(steps);
            Button review = ButtonText("打开 Codex 钩子审查", 190, delegate { if (!codexInstalled) { result.Text = "请先部署 Codex 提醒。"; return; } try { backend.ReviewHooks(); } catch { result.Text = "无法打开钩子审查，请查看 GitHub 安装教程。"; } }); Track(review);
            Button docs = ButtonText("查看中文使用教程", 180, delegate { OpenUrl("https://github.com/xinmiao0303/codex-phone-notifier"); }); flow.Controls.Add(ButtonRow(review, docs));
            Label location = LabelText("Codex 配置目录：" + directory + "\nClaude Code 配置目录：" + Path.Combine(claudeDirectory, "phone-notifier"), 48); location.Width = 810; flow.Controls.Add(location);
            Button codexFolder = ButtonText("打开 Codex 目录", 190, delegate { OpenFolder(directory); });
            Button claudeFolder = ButtonText("打开 Claude Code 目录", 190, delegate { OpenFolder(Path.Combine(claudeDirectory, "phone-notifier")); });
            flow.Controls.Add(ButtonRow(codexFolder, claudeFolder));
            Button codexLog = ButtonText("Codex 发送记录", 190, delegate { OpenFile(Path.Combine(directory, "ntfy-codex.log"), "Codex 还没有发送记录。"); });
            Button claudeLog = ButtonText("Claude Code 发送记录", 190, delegate { OpenFile(Path.Combine(claudeDirectory, "phone-notifier", "notifier.log"), "Claude Code 还没有发送记录。"); });
            flow.Controls.Add(ButtonRow(codexLog, claudeLog));
            Button iconSource = ButtonText("开源图标来源", 190, delegate { OpenUrl("https://github.com/lobehub/lobe-icons"); });
            Button iconLicense = ButtonText("查看图标许可", 190, delegate { if (backend != null) OpenFile(Path.Combine(backend.PayloadDirectory, "desktop", "assets", "ICON-NOTICE.txt"), "找不到图标许可文件。"); });
            flow.Controls.Add(ButtonRow(iconSource, iconLicense));
            Label help = LabelText("关闭“Codex 提醒”或“Claude Code 提醒”只暂停对应工具，钩子保留，不用重新信任或重启。关闭两个渠道可以暂停全部提醒，配置仍保留。软件不用一直开着，保存后可以直接关闭窗口。卸载只处理电脑端，不会卸载手机上的 ntfy 或微信。", 80); help.Width = 810; flow.Controls.Add(help);
        }
        private void Changed()
        {
            if (loading) return; dirty = true;
            if (result != null) result.Text = "有未保存的修改。点击保存后，新的开关才会生效。";
        }
        private bool Confirm(string message)
        { return MessageBox.Show(this, message, Text, MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes; }
        private void OpenUrl(string url)
        { try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); } catch { result.Text = "无法打开浏览器，请查看项目使用教程。"; } }
        private Dictionary<string, object> MakeRequest(string action, string channel, bool includeSettings)
        {
            Dictionary<string, object> request = new Dictionary<string, object> { { "action", action }, { "directory", directory }, { "claudeDirectory", claudeDirectory }, { "channel", channel }, { "keepConfig", keepConfig } };
            if (includeSettings)
            {
                Dictionary<string, object> settings = new Dictionary<string, object> { { "codexEnabled", codexEnabled.Checked }, { "claudeEnabled", claudeEnabled.Checked }, { "ntfyEnabled", ntfyEnabled.Checked }, { "wechatEnabled", wechatEnabled.Checked }, { "server", server.Text }, { "topic", topic.Text }, { "token", token.Text } };
                // 还没读到内容时不发送，避免把已有的自定义内容当成空白清掉。与默认相同的内容发空字符串，表示用默认。
                if (contentItems.Count > 0)
                {
                    Dictionary<string, object> content = new Dictionary<string, object> { { "shared", new Dictionary<string, object>() }, { "codex", new Dictionary<string, object>() }, { "claude", new Dictionary<string, object>() } };
                    foreach (ContentItem item in contentItems)
                    {
                        Dictionary<string, object> group = (Dictionary<string, object>)content[item.Tool];
                        group[item.TitleKey] = ContentText.Same(item.Title, item.DefaultTitle) ? "" : item.Title.Trim();
                        group[item.BodyKey] = ContentText.Same(item.Body, item.DefaultBody) ? "" : item.Body.Replace("\r\n", "\n").Trim();
                    }
                    settings["content"] = content;
                }
                request["settings"] = settings;
            }
            if (action == "preview") { request["tool"] = previewTool; request["event"] = previewEvent; }
            return request;
        }
        private async Task RunOperation(string action, string channel, bool includeSettings)
        {
            if (busy || preview) return;
            busy = true; foreach (Control control in operationControls) control.Enabled = false; UseWaitCursor = true; UpdateButtons();
            result.Text = action == "status" ? "正在读取本机设置…" : "正在处理，请稍等…";
            Dictionary<string, object> request = MakeRequest(action, channel, includeSettings);
            try
            {
                Dictionary<string, object> response = await Task.Run(delegate { return backend.Run(request); });
                bool ok = JsonValue.Flag(response, "ok");
                if (JsonValue.Object(response, "data") != null) ApplyStatus(JsonValue.Object(response, "data"));
                if (ok) { result.ForeColor = ink; }
                else result.ForeColor = danger;
                result.Text = JsonValue.Text(response, "message");
                if (!ok) MessageBox.Show(this, result.Text, Text, MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            catch (Exception) { result.Text = "操作未完成。请检查配置文件和网络，重新读取后再试。"; result.ForeColor = danger; }
            finally
            {
                Dictionary<string, object> values = JsonValue.Object(request, "settings"); if (values != null) values["token"] = null;
                busy = false; UseWaitCursor = false; foreach (Control control in operationControls) control.Enabled = true;
                UpdateButtons();
            }
        }
        private void ShowSource(Label label, bool isInstalled, bool isDetected, bool isEnabled, string tool)
        {
            if (isInstalled) { label.Text = isEnabled ? "已部署，提醒开启中" : "已部署，提醒已暂停（钩子保留）"; label.ForeColor = isEnabled ? good : warn; }
            else if (isDetected) { label.Text = "未部署。打开开关并保存即可部署。"; label.ForeColor = warn; }
            else { label.Text = "未检测到 " + tool + "，需要时也可以打开开关提前部署。"; label.ForeColor = muted; }
        }
        private void ApplyStatus(Dictionary<string, object> data)
        {
            if (data == null) return;
            loading = true;
            installed = JsonValue.Flag(data, "installed"); hasToken = JsonValue.Flag(data, "hasToken");
            codexInstalled = JsonValue.Flag(data, "codexInstalled"); claudeInstalled = JsonValue.Flag(data, "claudeInstalled");
            codexDetected = JsonValue.Flag(data, "codexDetected"); claudeDetected = JsonValue.Flag(data, "claudeDetected");
            codexEnabled.Checked = JsonValue.Flag(data, "codexEnabled"); claudeEnabled.Checked = JsonValue.Flag(data, "claudeEnabled");
            ntfyEnabled.Checked = JsonValue.Flag(data, "ntfyEnabled"); wechatEnabled.Checked = JsonValue.Flag(data, "wechatEnabled");
            server.Text = JsonValue.Text(data, "server"); topic.Text = JsonValue.Text(data, "topic"); token.Clear();
            if (!installed && String.IsNullOrWhiteSpace(topic.Text)) topic.Text = "codex-" + Guid.NewGuid().ToString("N").Substring(0, 24);
            tokenStatus.Text = hasToken ? "已保存 Token（已加密，不显示明文）" : "尚未保存 Token";
            tokenStatus.ForeColor = hasToken ? good : warn;
            ShowSource(codexStatus, codexInstalled, codexDetected, codexEnabled.Checked, "Codex");
            ShowSource(claudeStatus, claudeInstalled, claudeDetected, claudeEnabled.Checked, "Claude Code");
            string modes = ntfyEnabled.Checked && wechatEnabled.Checked ? "ntfy + 微信聊天" : ntfyEnabled.Checked ? "ntfy" : wechatEnabled.Checked ? "微信聊天" : "全部通知已暂停";
            string tools = !installed ? "尚未部署通知工具" : "Codex " + (codexInstalled ? (codexEnabled.Checked ? "开启" : "暂停") : "未部署") + "　·　Claude Code " + (claudeInstalled ? (claudeEnabled.Checked ? "开启" : "暂停") : "未部署");
            summary.Text = tools + "　 ·　 渠道：" + modes;
            if (data.ContainsKey("content"))
            {
                Dictionary<string, object> content = JsonValue.Object(data, "content");
                string selected = contentList.SelectedItem is ContentItem ? ((ContentItem)contentList.SelectedItem).Display : "";
                contentItems.Clear();
                foreach (string tool in new[] { "shared", "codex", "claude" })
                    foreach (object entry in JsonValue.List(content, tool))
                        if (entry is Dictionary<string, object>) contentItems.Add(ContentItem.From(tool, (Dictionary<string, object>)entry));
                contentList.BeginUpdate(); contentList.Items.Clear();
                int index = 0;
                for (int i = 0; i < contentItems.Count; i++) { contentList.Items.Add(contentItems[i]); if (contentItems[i].Display == selected) index = i; }
                contentList.EndUpdate();
                if (contentItems.Count > 0) contentList.SelectedIndex = index; else ShowContentItem();
            }
            dirty = false; loading = false; UpdateButtons();
        }
        private void UpdateButtons()
        {
            save.Text = installed ? "保存设置" : "部署并保存";
            testNtfy.Enabled = installed && !busy; testWechat.Enabled = installed && !busy;
            removeNtfy.Enabled = installed && !busy; removeWechat.Enabled = installed && !busy; uninstall.Enabled = installed && !busy;
            // 没部署、也没打开开关的工具，内容暂不能编辑：保存时不会写进它的配置。
            ContentItem item = contentList.SelectedItem as ContentItem;
            bool editable = item != null && CanEdit(item) && !busy;
            contentTitle.Enabled = editable; contentBody.Enabled = editable; contentReset.Enabled = editable;
            contentSend.Enabled = item != null && installed && !busy;
            if (item != null && !CanEdit(item)) contentHint.Text = item.Hint + "　打开上方的 " + (item.Tool == "codex" ? "Codex" : "Claude Code") + " 提醒后才能编辑。";
            else if (item != null) contentHint.Text = item.Hint;
        }
        public void RenderPreview(string path)
        {
            Opacity = 0; Show(); PerformLayout(); Application.DoEvents();
            using (Bitmap bitmap = new Bitmap(Width, Height)) { DrawToBitmap(bitmap, new Rectangle(Point.Empty, Size)); bitmap.Save(path, System.Drawing.Imaging.ImageFormat.Png); }
            dirty = false; Close();
        }
    }

    internal static class Program
    {
        [STAThread]
        private static void Main(string[] args)
        {
            Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
            try
            {
                if (args.Length >= 2 && args[0] == "--render-preview") { using (MainForm form = new MainForm(null, true, args.Length > 2 ? args[2] : "")) form.RenderPreview(Path.GetFullPath(args[1])); return; }
                if (args.Length == 2 && args[0] == "--self-check") { SelfCheck(Path.GetFullPath(args[1])); return; }
                using (MainForm form = new MainForm(new DesktopBackend(), false)) Application.Run(form);
            }
            catch (Exception) { Environment.ExitCode = 1; if (args.Length == 0) MessageBox.Show("软件无法启动。请重新下载；如果仍有问题，请在 GitHub 反馈。", "Codex 与 Claude Code 手机提醒", MessageBoxButtons.OK, MessageBoxIcon.Error); }
        }
        private static void SelfCheck(string resultFile)
        {
            string tempRoot = Path.GetFullPath(Path.GetTempPath());
            string directory = Path.Combine(tempRoot, "codex-phone-gui-test-" + Guid.NewGuid().ToString("N"));
            string claudeDirectory = Path.Combine(directory, "claude 用户目录");
            int checks = 0;
            try
            {
                DesktopBackend backend = new DesktopBackend();
                Dictionary<string, object> request = new Dictionary<string, object> { { "action", "status" }, { "directory", directory }, { "claudeDirectory", claudeDirectory } };
                Dictionary<string, object> response = backend.Run(request);
                Verify(JsonValue.Flag(response,"ok") && !JsonValue.Flag(JsonValue.Object(response,"data"),"installed"), ref checks);
                Dictionary<string, object> settings = new Dictionary<string, object> { { "codexEnabled", true }, { "claudeEnabled", true }, { "ntfyEnabled", false }, { "wechatEnabled", true }, { "server", "https://ntfy.sh" }, { "topic", "codex-gui-test-topic" }, { "token", "gui-test-token-not-a-real-secret" } };
                request["action"] = "install"; request["settings"] = settings;
                response = backend.Run(request); Verify(JsonValue.Flag(response,"ok"), ref checks);
                Dictionary<string, object> data = JsonValue.Object(response,"data");
                Verify(JsonValue.Flag(data,"codexInstalled") && JsonValue.Flag(data,"claudeInstalled") && JsonValue.Flag(data,"hasToken") && !JsonValue.Flag(data,"ntfyEnabled") && JsonValue.Flag(data,"wechatEnabled"), ref checks);
                string claudeSettings = Path.Combine(claudeDirectory, "settings.json");
                Verify(File.Exists(claudeSettings) && File.ReadAllText(claudeSettings).Contains("notify.ps1") && File.Exists(Path.Combine(claudeDirectory, "phone-notifier", "pushplus-token.dpapi")), ref checks);
                Verify(!new JavaScriptSerializer().Serialize(response).Contains("gui-test-token-not-a-real-secret"), ref checks);
                settings["token"] = ""; settings["wechatEnabled"] = false; settings["codexEnabled"] = false; request["action"] = "save";
                settings["content"] = new Dictionary<string, object> { { "shared", new Dictionary<string, object> { { "testTitle", "自检测试标题" } } }, { "claude", new Dictionary<string, object> { { "body", "自检正文\n电脑：{电脑}" } } }, { "codex", new Dictionary<string, object>() } };
                response = backend.Run(request); data = JsonValue.Object(response,"data");
                Verify(JsonValue.Flag(response,"ok") && JsonValue.Flag(data,"hasToken") && !JsonValue.Flag(data,"wechatEnabled") && !JsonValue.Flag(data,"codexEnabled") && JsonValue.Flag(data,"claudeEnabled"), ref checks);
                string claudeConfig = File.ReadAllText(Path.Combine(claudeDirectory, "phone-notifier", "config.json")), codexConfig = File.ReadAllText(Path.Combine(directory, "ntfy-codex.json"));
                Verify(claudeConfig.Contains("自检测试标题") && claudeConfig.Contains("自检正文") && codexConfig.Contains("自检测试标题") && !codexConfig.Contains("自检正文"), ref checks);
                request["action"] = "remove-wechat"; response = backend.Run(request);
                Verify(JsonValue.Flag(response,"ok") && !JsonValue.Flag(JsonValue.Object(response,"data"),"hasToken"), ref checks);
                request["action"] = "uninstall"; request["keepConfig"] = false; response = backend.Run(request);
                Verify(JsonValue.Flag(response,"ok") && !JsonValue.Flag(JsonValue.Object(response,"data"),"installed"), ref checks);
                Verify(!File.Exists(Path.Combine(directory,"ntfy-codex.json")) && !File.Exists(Path.Combine(claudeDirectory,"phone-notifier","config.json")), ref checks);
                File.WriteAllText(resultFile, new JavaScriptSerializer().Serialize(new { ok = true, checks = checks }), new UTF8Encoding(false));
            }
            catch (Exception)
            {
                Environment.ExitCode = 1;
                File.WriteAllText(resultFile, new JavaScriptSerializer().Serialize(new { ok = false, checks = checks }), new UTF8Encoding(false));
            }
            finally
            {
                string target = Path.GetFullPath(directory);
                if (Directory.Exists(target) && target.StartsWith(Path.Combine(tempRoot,"codex-phone-gui-test-"),StringComparison.OrdinalIgnoreCase)) Directory.Delete(target,true);
            }
        }
        private static void Verify(bool condition, ref int checks)
        { if (!condition) throw new InvalidOperationException("Self check failed"); checks++; }
    }
}
