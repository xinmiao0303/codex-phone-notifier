using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

[assembly: AssemblyTitle("Codex 手机提醒")]
[assembly: AssemblyDescription("ntfy 与微信 ClawBot 的 Windows 图形配置工具")]
[assembly: AssemblyVersion("0.4.2.0")]
[assembly: AssemblyFileVersion("0.4.2.0")]

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
            PayloadDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodexPhoneNotifier", "0.4.2-" + hash);
            Directory.CreateDirectory(PayloadDirectory);
            string[] files = { "install.ps1", "uninstall.ps1", "review-hooks.ps1", "scripts/common.ps1", "scripts/notify.ps1", "desktop/desktop-backend.ps1", "desktop/assets/LUCIDE-LICENSE.txt", "desktop/assets/ICON-NOTICE.txt", "desktop/assets/LOBE-ICONS-LICENSE.txt", "LICENSE" };
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
                if (!process.WaitForExit(30000)) { process.Kill(); throw new InvalidOperationException("操作超过三十秒，请检查网络后重试。"); }
                string output = stdout.GetAwaiter().GetResult().Trim().TrimStart('\uFEFF');
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
        private readonly string directory;
        private bool installed, hasToken, busy, loading, dirty;
        private CheckBox ntfyEnabled, wechatEnabled, keepConfig;
        private TextBox server, topic, token, result;
        private Label summary, tokenStatus;
        private Button save, install, refresh, testNtfy, testWechat, removeNtfy, removeWechat, uninstall;
        private readonly List<Control> operationControls = new List<Control>();
        private readonly Color ink = Color.FromArgb(32, 42, 62), blue = Color.FromArgb(41, 94, 218);
        public MainForm(DesktopBackend service, bool isPreview)
        {
            backend = service; preview = isPreview;
            directory = Environment.GetEnvironmentVariable("CODEX_HOME");
            if (String.IsNullOrWhiteSpace(directory)) directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex");
            Text = "Codex 手机提醒"; StartPosition = FormStartPosition.CenterScreen;
            Font = new Font("Microsoft YaHei UI", 9F); ForeColor = ink;
            BackColor = Color.FromArgb(243, 246, 251); AutoScaleMode = AutoScaleMode.Dpi;
            ClientSize = new Size(960, Math.Min(790, Screen.PrimaryScreen.WorkingArea.Height - 80)); MinimumSize = new Size(890, 650);
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
                ApplyStatus(new Dictionary<string, object> { { "installed", true }, { "hasToken", true }, { "ntfyEnabled", false }, { "wechatEnabled", true }, { "server", "https://ntfy.sh" }, { "topic", "codex-demo-topic-for-preview" } });
                result.Text = "微信聊天通知已开启，ntfy 已暂停。主题和加密 Token 会保留，随时可以恢复。";
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
        private FlowLayoutPanel Card(TableLayoutPanel parent, int column)
        {
            Panel panel = new Panel { Dock = DockStyle.Fill, BackColor = Color.White, Padding = new Padding(18), Margin = column == 0 ? new Padding(0, 0, 8, 0) : new Padding(8, 0, 0, 0) };
            FlowLayoutPanel flow = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoScroll = true };
            panel.Controls.Add(flow); parent.Controls.Add(panel, column, 0);
            flow.Layout += delegate { int width = Math.Max(260, flow.ClientSize.Width - SystemInformation.VerticalScrollBarWidth - 6); foreach (Control child in flow.Controls) if (child.Width != width) child.Width = width; };
            return flow;
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
        private void BuildInterface()
        {
            TableLayoutPanel root = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(24, 18, 24, 16), RowCount = 4, ColumnCount = 1 };
            root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            root.RowStyles.Add(new RowStyle(SizeType.Absolute, 66)); root.RowStyles.Add(new RowStyle(SizeType.Absolute, 36));
            root.RowStyles.Add(new RowStyle(SizeType.Percent, 100)); root.RowStyles.Add(new RowStyle(SizeType.Absolute, 118));
            Controls.Add(root);
            Panel heading = new Panel { Dock = DockStyle.Fill };
            heading.Controls.Add(new Label { Text = "Codex 手机提醒", Font = new Font(Font.FontFamily, 20, FontStyle.Bold), AutoSize = true, Location = new Point(0, 0), ForeColor = ink });
            heading.Controls.Add(new Label { Text = "做完任务，或等你回答时，让手机提醒你。", AutoSize = true, Location = new Point(2, 41), ForeColor = Color.FromArgb(94, 109, 132) });
            Label version = new Label { Text = "v0.4.2", AutoSize = true, Anchor = AnchorStyles.Top | AnchorStyles.Right, Location = new Point(834, 10), ForeColor = Color.FromArgb(94, 109, 132) };
            heading.Controls.Add(version); root.Controls.Add(heading, 0, 0);
            summary = new Label { Text = "正在读取本机设置…", Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft, ForeColor = blue };
            root.Controls.Add(summary, 0, 1);
            TabControl tabs = new TabControl { Dock = DockStyle.Fill, Padding = new Point(18, 7) };
            TabPage notificationPage = new TabPage("通知渠道") { BackColor = BackColor, Padding = new Padding(12) };
            TabPage helpPage = new TabPage("安装与帮助") { BackColor = Color.White, Padding = new Padding(20) };
            tabs.TabPages.Add(notificationPage); tabs.TabPages.Add(helpPage); root.Controls.Add(tabs, 0, 2);
            TableLayoutPanel cards = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 1, ColumnCount = 2 };
            cards.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50)); cards.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50)); cards.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            notificationPage.Controls.Add(cards);
            FlowLayoutPanel n = Card(cards, 0);
            ntfyEnabled = new CheckBox { Text = "启用 ntfy 手机通知", Height = 34, Width = 390, Font = new Font(Font.FontFamily, 12, FontStyle.Bold), Margin = new Padding(0, 0, 0, 6) };
            ntfyEnabled.CheckedChanged += delegate { Changed(); }; Track(ntfyEnabled); n.Controls.Add(ntfyEnabled);
            n.Controls.Add(LabelText("消息发到 ntfy App。手机订阅下面的主题，就能收到提醒。", 38));
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
                if (Confirm("这会关闭 ntfy，并移除本机的服务器、主题和认证设置。微信及 Codex 钩子保留。继续？")) await RunOperation("remove-ntfy", "", false);
            }); Track(removeNtfy); n.Controls.Add(removeNtfy);
            FlowLayoutPanel w = Card(cards, 1);
            wechatEnabled = new CheckBox { Text = "启用微信聊天通知", Height = 34, Width = 390, Font = new Font(Font.FontFamily, 12, FontStyle.Bold), Margin = new Padding(0, 0, 0, 6) };
            wechatEnabled.CheckedChanged += delegate { Changed(); }; Track(wechatEnabled); w.Controls.Add(wechatEnabled);
            w.Controls.Add(LabelText("通过 PushPlus ClawBot，发到你自己的微信机器人聊天。", 38));
            tokenStatus = LabelText("尚未保存 Token", 19); w.Controls.Add(tokenStatus);
            w.Controls.Add(LabelText("用户 Token（留空就保留已有密钥）", 19)); token = TextInput(true); w.Controls.Add(token);
            w.Controls.Add(LabelText("密钥只在本机加密保存，不会显示已有 Token，也不会写进通知。", 38));
            Button pushplus = ButtonText("打开 PushPlus", 160, delegate { OpenUrl("https://www.pushplus.plus/push1.html"); });
            Button binding = ButtonText("绑定机器人教程", 148, delegate { OpenUrl("https://www.pushplus.plus/doc/channel/clawbot.html"); });
            w.Controls.Add(ButtonRow(pushplus, binding));
            Label requirement = LabelText("先在网站完成实名、扫码绑定并激活。每十条推送后，以及至少每二十四小时，要主动给机器人发一句话。", 60);
            requirement.ForeColor = Color.FromArgb(151, 90, 24); w.Controls.Add(requirement);
            testWechat = ButtonText("保存并测试微信", 320, async delegate { await RunOperation("test", "wechat", true); }); Track(testWechat); w.Controls.Add(testWechat);
            removeWechat = ButtonText("移除微信配置", 320, async delegate
            {
                if (Confirm("这会关闭微信，并删除本机保存的加密 Token。ntfy 和 Codex 钩子保留。继续？")) await RunOperation("remove-wechat", "", false);
            }); Track(removeWechat); w.Controls.Add(removeWechat);
            BuildHelp(helpPage);
            TableLayoutPanel footer = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 3, Padding = new Padding(0, 12, 0, 0) };
            footer.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            footer.RowStyles.Add(new RowStyle(SizeType.Absolute, 22)); footer.RowStyles.Add(new RowStyle(SizeType.Absolute, 40)); footer.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            footer.Controls.Add(new Label { Text = "更改开关后点击保存。测试按钮会先保存当前设置，再单独测试对应渠道。", AutoSize = true, ForeColor = Color.FromArgb(94, 109, 132) }, 0, 0);
            FlowLayoutPanel actions = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = false };
            save = ButtonText("保存设置", 140, async delegate { await RunOperation(installed ? "save" : "install", "", true); });
            save.BackColor = blue; save.ForeColor = Color.White; save.FlatAppearance.BorderColor = blue;
            install = ButtonText("安装 / 更新通知工具", 200, async delegate { await RunOperation("install", "", true); });
            refresh = ButtonText("重新读取", 110, async delegate { if (!dirty || Confirm("重新读取会放弃未保存的修改。继续？")) await RunOperation("status", "", false); });
            Track(save); Track(install); Track(refresh); actions.Controls.Add(save); actions.Controls.Add(install); actions.Controls.Add(refresh); footer.Controls.Add(actions, 0, 1);
            result = new TextBox { Dock = DockStyle.Fill, Multiline = true, ReadOnly = true, BorderStyle = BorderStyle.None, BackColor = BackColor, ForeColor = ink, Text = "正在读取设置。", TabStop = false };
            footer.Controls.Add(result, 0, 2); root.Controls.Add(footer, 0, 3);
        }
        private void BuildHelp(TabPage page)
        {
            FlowLayoutPanel flow = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoScroll = true };
            page.Controls.Add(flow);
            Label title = LabelText("第一次使用，按这四步完成", 32); title.Font = new Font(Font.FontFamily, 14, FontStyle.Bold); title.Width = 810; flow.Controls.Add(title);
            Label steps = LabelText("1. 填写需要使用的渠道，点击“安装 / 更新通知工具”。\n\n2. 打开钩子审查，检查本工具的命令后再信任。\n\n3. 首次安装后，完整退出并重新打开 Codex。\n\n4. 测试手机，再让 Codex 完成一次任务、弹出一道问题。", 180); steps.Width = 810; flow.Controls.Add(steps);
            Button review = ButtonText("打开钩子审查", 170, delegate { if (!installed) { result.Text = "请先安装通知工具。"; return; } try { backend.ReviewHooks(); } catch { result.Text = "无法打开钩子审查，请查看 GitHub 安装教程。"; } }); Track(review);
            Button docs = ButtonText("查看中文使用教程", 180, delegate { OpenUrl("https://github.com/xinmiao0303/codex-phone-notifier"); }); flow.Controls.Add(ButtonRow(review, docs));
            Label location = LabelText("本机配置目录：" + directory, 48); location.Width = 810; flow.Controls.Add(location);
            Button folder = ButtonText("打开配置目录", 170, delegate { if (Directory.Exists(directory)) Process.Start(new ProcessStartInfo("explorer.exe", "\"" + directory + "\"") { UseShellExecute = true }); else result.Text = "安装后会自动创建配置目录。"; });
            Button logs = ButtonText("查看发送记录", 180, delegate
            {
                string path = Path.Combine(directory, "ntfy-codex.log");
                if (File.Exists(path)) Process.Start(new ProcessStartInfo("notepad.exe", "\"" + path + "\"") { UseShellExecute = true }); else result.Text = "还没有发送记录。";
            }); flow.Controls.Add(ButtonRow(folder, logs));
            keepConfig = new CheckBox { Text = "卸载时保留主题和加密 Token，方便以后重装", Checked = true, Width = 810, Height = 30, Margin = new Padding(0, 12, 0, 8) }; Track(keepConfig); flow.Controls.Add(keepConfig);
            uninstall = ButtonText("卸载通知工具", 190, async delegate
            {
                string hint = keepConfig.Checked ? "卸载会移除本工具的自动通知钩子和发送脚本，保留主题及加密 Token。其他 Codex 配置保留。继续？" : "卸载会移除本工具的钩子、脚本、配置和加密 Token。其他 Codex 配置保留，原文件会先备份。继续？";
                if (Confirm(hint)) await RunOperation("uninstall", "", false);
            }); uninstall.ForeColor = Color.FromArgb(169, 48, 57); Track(uninstall); flow.Controls.Add(uninstall);
            Button iconSource = ButtonText("开源图标来源", 170, delegate { OpenUrl("https://github.com/lobehub/lobe-icons"); });
            Button iconLicense = ButtonText("查看图标许可", 180, delegate { if (backend != null) Process.Start(new ProcessStartInfo("notepad.exe", "\"" + Path.Combine(backend.PayloadDirectory,"desktop","assets","ICON-NOTICE.txt") + "\"") { UseShellExecute = true }); });
            flow.Controls.Add(ButtonRow(iconSource, iconLicense));
            Label help = LabelText("关闭两个渠道可以暂停全部提醒，配置仍保留。软件不用一直开着，保存后可以直接关闭窗口。卸载只处理电脑端，不会卸载手机上的 ntfy 或微信。", 60); help.Width = 810; flow.Controls.Add(help);
        }
        private void Changed()
        {
            if (loading) return; dirty = true;
            if (result != null) result.Text = "有未保存的修改。点击保存后，新的渠道开关才会生效。";
        }
        private bool Confirm(string message)
        { return MessageBox.Show(this, message, Text, MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes; }
        private void OpenUrl(string url)
        { try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); } catch { result.Text = "无法打开浏览器，请查看项目使用教程。"; } }
        private Dictionary<string, object> MakeRequest(string action, string channel, bool includeSettings)
        {
            Dictionary<string, object> request = new Dictionary<string, object> { { "action", action }, { "directory", directory }, { "channel", channel }, { "keepConfig", keepConfig.Checked } };
            if (includeSettings) request["settings"] = new Dictionary<string, object> { { "ntfyEnabled", ntfyEnabled.Checked }, { "wechatEnabled", wechatEnabled.Checked }, { "server", server.Text }, { "topic", topic.Text }, { "token", token.Text } };
            return request;
        }
        private async Task RunOperation(string action, string channel, bool includeSettings)
        {
            if (busy || preview) return;
            busy = true; foreach (Control control in operationControls) control.Enabled = false; UseWaitCursor = true;
            result.Text = action == "status" ? "正在读取本机设置…" : "正在处理，请稍等…";
            Dictionary<string, object> request = MakeRequest(action, channel, includeSettings);
            try
            {
                Dictionary<string, object> response = await Task.Run(delegate { return backend.Run(request); });
                bool ok = JsonValue.Flag(response, "ok");
                if (JsonValue.Object(response, "data") != null) ApplyStatus(JsonValue.Object(response, "data"));
                if (ok) { result.ForeColor = ink; }
                else result.ForeColor = Color.FromArgb(169, 48, 57);
                result.Text = JsonValue.Text(response, "message");
                if (!ok) MessageBox.Show(this, result.Text, Text, MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            catch (Exception) { result.Text = "操作未完成。请检查配置文件和网络，重新读取后再试。"; result.ForeColor = Color.FromArgb(169, 48, 57); }
            finally
            {
                Dictionary<string, object> values = JsonValue.Object(request, "settings"); if (values != null) values["token"] = null;
                busy = false; UseWaitCursor = false; foreach (Control control in operationControls) control.Enabled = true;
                UpdateButtons();
            }
        }
        private void ApplyStatus(Dictionary<string, object> data)
        {
            if (data == null) return;
            loading = true;
            installed = JsonValue.Flag(data, "installed"); hasToken = JsonValue.Flag(data, "hasToken");
            ntfyEnabled.Checked = JsonValue.Flag(data, "ntfyEnabled"); wechatEnabled.Checked = JsonValue.Flag(data, "wechatEnabled");
            server.Text = JsonValue.Text(data, "server"); topic.Text = JsonValue.Text(data, "topic"); token.Clear();
            if (!installed && String.IsNullOrWhiteSpace(topic.Text)) topic.Text = "codex-" + Guid.NewGuid().ToString("N").Substring(0, 24);
            tokenStatus.Text = hasToken ? "已保存 Token（已加密，不显示明文）" : "尚未保存 Token";
            tokenStatus.ForeColor = hasToken ? Color.FromArgb(30, 123, 93) : Color.FromArgb(151, 90, 24);
            string modes = ntfyEnabled.Checked && wechatEnabled.Checked ? "ntfy + 微信聊天" : ntfyEnabled.Checked ? "ntfy" : wechatEnabled.Checked ? "微信聊天" : "全部通知已暂停";
            summary.Text = (installed ? "通知工具已安装　 ·　 " : "尚未安装通知工具　 ·　 ") + modes;
            dirty = false; loading = false; UpdateButtons();
        }
        private void UpdateButtons()
        {
            save.Text = installed ? "保存设置" : "安装并保存";
            testNtfy.Enabled = installed && !busy; testWechat.Enabled = installed && !busy;
            removeNtfy.Enabled = installed && !busy; removeWechat.Enabled = installed && !busy; uninstall.Enabled = installed && !busy;
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
                if (args.Length == 2 && args[0] == "--render-preview") { using (MainForm form = new MainForm(null, true)) form.RenderPreview(Path.GetFullPath(args[1])); return; }
                if (args.Length == 2 && args[0] == "--self-check") { SelfCheck(Path.GetFullPath(args[1])); return; }
                using (MainForm form = new MainForm(new DesktopBackend(), false)) Application.Run(form);
            }
            catch (Exception) { Environment.ExitCode = 1; if (args.Length == 0) MessageBox.Show("软件无法启动。请重新下载；如果仍有问题，请在 GitHub 反馈。", "Codex 手机提醒", MessageBoxButtons.OK, MessageBoxIcon.Error); }
        }
        private static void SelfCheck(string resultFile)
        {
            string tempRoot = Path.GetFullPath(Path.GetTempPath());
            string directory = Path.Combine(tempRoot, "codex-phone-gui-test-" + Guid.NewGuid().ToString("N"));
            int checks = 0;
            try
            {
                DesktopBackend backend = new DesktopBackend();
                Dictionary<string, object> request = new Dictionary<string, object> { { "action", "status" }, { "directory", directory } };
                Dictionary<string, object> response = backend.Run(request);
                Verify(JsonValue.Flag(response,"ok") && !JsonValue.Flag(JsonValue.Object(response,"data"),"installed"), ref checks);
                Dictionary<string, object> settings = new Dictionary<string, object> { { "ntfyEnabled", false }, { "wechatEnabled", true }, { "server", "https://ntfy.sh" }, { "topic", "codex-gui-test-topic" }, { "token", "gui-test-token-not-a-real-secret" } };
                request["action"] = "install"; request["settings"] = settings;
                response = backend.Run(request); Verify(JsonValue.Flag(response,"ok"), ref checks);
                Dictionary<string, object> data = JsonValue.Object(response,"data");
                Verify(JsonValue.Flag(data,"installed") && JsonValue.Flag(data,"hasToken") && !JsonValue.Flag(data,"ntfyEnabled") && JsonValue.Flag(data,"wechatEnabled"), ref checks);
                Verify(!new JavaScriptSerializer().Serialize(response).Contains("gui-test-token-not-a-real-secret"), ref checks);
                settings["token"] = ""; settings["wechatEnabled"] = false; request["action"] = "save";
                response = backend.Run(request); data = JsonValue.Object(response,"data");
                Verify(JsonValue.Flag(response,"ok") && JsonValue.Flag(data,"hasToken") && !JsonValue.Flag(data,"wechatEnabled") && !JsonValue.Flag(data,"ntfyEnabled"), ref checks);
                request["action"] = "remove-wechat"; response = backend.Run(request);
                Verify(JsonValue.Flag(response,"ok") && !JsonValue.Flag(JsonValue.Object(response,"data"),"hasToken"), ref checks);
                request["action"] = "uninstall"; request["keepConfig"] = false; response = backend.Run(request);
                Verify(JsonValue.Flag(response,"ok") && !JsonValue.Flag(JsonValue.Object(response,"data"),"installed") && !File.Exists(Path.Combine(directory,"ntfy-codex.json")), ref checks);
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
