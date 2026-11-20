using System.Diagnostics;
using System.Globalization;
using System.Text.Json;

namespace TokenTrackerLite;

internal static class Program
{
    [STAThread] private static void Main(string[] args)
    {
        Application.SetHighDpiMode(args.Length == 2 && args[0] == "--verify-layout-96" ? HighDpiMode.DpiUnaware : HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
        Application.SetDefaultFont(new Font("Microsoft YaHei UI", 9));
        if (args.Length == 2 && args[0] is "--verify-layout" or "--verify-layout-96") { LayoutVerification.Run(args[1]); return; }
        using var mutex = new Mutex(true, "Local\\TokenTrackerLite", out var first);
        if (!first) { MessageBox.Show("应用已运行，请从系统托盘打开。", "TokenTracker Lite"); return; }
        Application.Run(new TrackerWindow());
    }
}

internal sealed partial class TrackerWindow : Form
{
    private static readonly Color Background = Color.FromArgb(30, 30, 30), Card = Color.FromArgb(43, 43, 43),
        TextColor = Color.FromArgb(230, 230, 230), Secondary = Color.FromArgb(161, 161, 166), Accent = Color.FromArgb(50, 145, 255);
    private readonly Panel viewport = new() { Dock = DockStyle.Fill, AutoScroll = true, BackColor = Background };
    private readonly TableLayoutPanel content = new() { Dock = DockStyle.Top, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
        ColumnCount = 1, RowCount = 0, Padding = new Padding(18), Margin = Padding.Empty, BackColor = Background };
    private readonly Label apiTitle = new(), localState = new(), collected = new();
    private readonly Label[] apiValues = new Label[6], apiNotes = new Label[6], localValues = new Label[3], localCosts = new Label[3];
    private readonly TableLayoutPanel days = new(), models = new();
    private readonly Button remoteRefresh;
    private readonly NotifyIcon tray;
    private readonly System.Windows.Forms.Timer timer = new() { Interval = 30000 };
    private readonly CancellationTokenSource lifetime = new();
    private CancellationTokenSource? request;
    private readonly string support = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "TokenTrackerLite");
    private readonly string queue = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".tokentracker", "tracker", "queue.jsonl");
    private string ApiCache => Path.Combine(support, "topapi-snapshot.json");
    private string LocalCache => Path.Combine(support, "snapshot.json");
    private string? key, apiError;
    private ApiSnapshot? snapshot;
    private DateTimeOffset lastAttempt = DateTimeOffset.MinValue;
    private bool remoteBusy, localBusy, quitting;
    private int generation;
    private string localStamp = "";
    private DateTimeOffset lastLocalAttempt = DateTimeOffset.MinValue;
    private Process? worker;
    private bool fittingHeight, autoFitHeight = true;
    private Size resizeStart;

    public TrackerWindow(bool layoutVerification = false)
    {
        SuspendLayout(); content.SuspendLayout();
        // 所有设计尺寸统一以 96 DPI 为基准，只让 WinForms 缩放一次。
        AutoScaleDimensions = new SizeF(96, 96); AutoScaleMode = AutoScaleMode.Dpi;
        Text = "TokenTracker Lite"; BackColor = Background; ForeColor = TextColor;
        ClientSize = new Size(520, 780); MinimumSize = new Size(480, 460); StartPosition = FormStartPosition.CenterScreen;
        DoubleBuffered = true;
        Icon = Icon.ExtractAssociatedIcon(Environment.ProcessPath!) ?? SystemIcons.Application;
        content.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        viewport.Controls.Add(content); Controls.Add(viewport);
        var title = Label("TokenTracker Lite", 18, TextColor, FontStyle.Bold);
        title.Name = "AppTitle"; title.AutoSize = false; title.AutoEllipsis = true; title.TextAlign = ContentAlignment.MiddleLeft;
        var heading = new TableLayoutPanel { ColumnCount = 2, RowCount = 1, Margin = Padding.Empty };
        heading.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        heading.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 30)); heading.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        var logo = new PictureBox { Image = Icon.ToBitmap(), SizeMode = PictureBoxSizeMode.Zoom, Dock = DockStyle.Fill, Margin = new Padding(0, 6, 8, 6) };
        title.Dock = DockStyle.Fill; heading.Controls.Add(logo, 0, 0); heading.Controls.Add(title, 1, 0);
        Add(heading, 44);
        Add(Cards(["今日", "本月", "累计"], localValues, localCosts, false), 95);

        var header = new Panel(); apiTitle.Text = "● api-top.com"; apiTitle.ForeColor = Secondary;
        apiTitle.AutoSize = false; apiTitle.AutoEllipsis = true; apiTitle.Dock = DockStyle.Fill; apiTitle.TextAlign = ContentAlignment.MiddleLeft;
        var settings = Button("设置", (_, _) => ShowSettings()); settings.Dock = DockStyle.Right; settings.Width = 55;
        remoteRefresh = Button("刷新", async (_, _) => await RefreshRemote(true)); remoteRefresh.Dock = DockStyle.Right; remoteRefresh.Width = 55;
        header.Controls.Add(apiTitle); header.Controls.Add(remoteRefresh); header.Controls.Add(settings); Add(header, 32);
        Add(Cards(["今日使用", "本周已用", "本周剩余"], apiValues, apiNotes, true), 95);
        Add(Cards(["账户余额", "套餐周期", "套餐剩余天数"], apiValues, apiNotes, true, offset: 3), 95);
        apiValues[2].ForeColor = Accent;

        Add(Label("近 7 天", 10, Secondary, FontStyle.Bold), 25); ConfigureRows(days); Add(days);
        Add(Label("本月模型 Top 5", 10, Secondary, FontStyle.Bold), 25); ConfigureRows(models); Add(models);
        localState.ForeColor = Color.Orange; localState.AutoSize = true; localState.Visible = false;
        localState.TextChanged += (_, _) => {
            localState.Visible = !string.IsNullOrWhiteSpace(localState.Text);
            if (IsHandleCreated && !IsDisposed) BeginInvoke(new Action(FitHeightToContent));
        };
        Add(localState);
        Add(Label("本机统计 · 费用为估算", 9, Secondary), 24);
        collected.ForeColor = Secondary; collected.AutoSize = true; Add(collected);
        var footer = new Panel();
        var refresh = Button("刷新统计", async (_, _) => await Task.WhenAll(RefreshLocal(true), RefreshRemote(true)));
        refresh.Dock = DockStyle.Left; refresh.Width = 100;
        var quit = Button("退出", (_, _) => Exit()); quit.Dock = DockStyle.Right; quit.Width = 55;
        footer.Controls.Add(refresh); footer.Controls.Add(quit); Add(footer, 32);

        tray = new NotifyIcon { Icon = Icon, Text = "", Visible = !layoutVerification };
        var menu = new ContextMenuStrip(); menu.Items.Add("显示统计窗口", null, (_, _) => ShowWindow());
        menu.Items.Add("API 监控设置", null, (_, _) => ShowSettings()); menu.Items.Add("退出", null, (_, _) => Exit());
        tray.ContextMenuStrip = menu; tray.DoubleClick += (_, _) => ShowWindow();
        HandleCreated += (_, _) => NativeTheme.ApplyDarkTitleBar(Handle);
        Shown += (_, _) => {
            UpdateMinimumWindowSize();
            var workingArea = Screen.FromControl(this).WorkingArea;
            var maximum = new Size(Math.Max(1, workingArea.Width - LogicalToDeviceUnits(32)), Math.Max(1, workingArea.Height - LogicalToDeviceUnits(32)));
            Size = new Size(Math.Min(Width, maximum.Width), Math.Min(Height, maximum.Height));
            CenterToScreen();
        };
        DpiChanged += (_, _) => BeginInvoke(new Action(() => { UpdateMinimumWindowSize(); FitHeightToContent(); }));
        ResizeBegin += (_, _) => resizeStart = Size;
        ResizeEnd += (_, _) => { if (Size != resizeStart) autoFitHeight = false; };
        timer.Tick += async (_, _) => { RenderRemote(); await Task.WhenAll(RefreshLocal(), RefreshRemote()); };
        Shown += async (_, _) => { if (layoutVerification) return; ResizeRows(); LoadCached(); FitHeightToContent(); timer.Start(); await Task.WhenAll(RefreshLocal(true), RefreshRemote(true)); };
        FormClosing += (_, e) => {
            if (e.CloseReason == CloseReason.UserClosing && !quitting) { e.Cancel = true; Hide(); return; }
            timer.Stop(); lifetime.Cancel(); request?.Cancel(); tray.Visible = false;
            if (worker is { HasExited: false }) worker.Kill(true);
        };
        FormClosed += (_, _) => { timer.Dispose(); request?.Dispose(); lifetime.Dispose(); tray.Dispose(); };
        content.ResumeLayout(true); ResumeLayout(true);
    }

    private static Label Label(string value, float size = 10, Color? color = null, FontStyle weight = FontStyle.Regular) =>
        new() { Text = value, AutoSize = true, ForeColor = color ?? TextColor, Font = new Font("Microsoft YaHei UI", size, weight), BackColor = Color.Transparent, Margin = new Padding(0) };
    private static Button Button(string title, EventHandler handler)
    {
        var button = new MonitorButton { Text = title, ForeColor = Accent, BackColor = Background, Cursor = Cursors.Hand, TabStop = true };
        button.Click += handler; return button;
    }
    private void Add(Control view, int height = 0)
    {
        var row = content.RowCount++;
        view.Margin = new Padding(0, 0, 0, 8);
        view.Dock = DockStyle.Fill;
        if (height > 0) { view.AutoSize = false; content.RowStyles.Add(new RowStyle(SizeType.Absolute, height)); }
        else { view.AutoSize = true; content.RowStyles.Add(new RowStyle(SizeType.AutoSize)); }
        content.Controls.Add(view, 0, row);
    }
    private static TableLayoutPanel Cards(string[] titles, Label[] values, Label[] notes, bool api, int offset = 0)
    {
        var table = new TableLayoutPanel { ColumnCount = titles.Length, RowCount = 1, Margin = Padding.Empty, Padding = Padding.Empty };
        table.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        for (int i = 0; i < titles.Length; i++)
        {
            var index = i + offset;
            table.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f / titles.Length));
            var panel = new MetricCard { Dock = DockStyle.Fill, Margin = new Padding(i == 0 ? 0 : 4, 0, i == titles.Length - 1 ? 0 : 4, 0), Padding = new Padding(9, 8, 9, 8) };
            panel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            panel.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            panel.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            panel.RowStyles.Add(new RowStyle(SizeType.Absolute, 18));
            var heading = Label(titles[i], 9, Secondary); heading.Dock = DockStyle.Fill; heading.AutoSize = true;
            values[index] = Label("—", api ? 16 : 20, TextColor, FontStyle.Bold);
            values[index].AutoSize = false; values[index].AutoEllipsis = true; values[index].TextAlign = ContentAlignment.MiddleLeft; values[index].Dock = DockStyle.Fill;
            notes[index] = Label(api ? "等待账单" : "等待统计", 8, Secondary);
            notes[index].Dock = DockStyle.Fill; notes[index].AutoSize = false; notes[index].AutoEllipsis = true; notes[index].TextAlign = ContentAlignment.MiddleLeft;
            panel.Controls.Add(heading, 0, 0); panel.Controls.Add(values[index], 0, 1); panel.Controls.Add(notes[index], 0, 2);
            table.Controls.Add(panel, i, 0);
        }
        return table;
    }
    private static void ConfigureRows(TableLayoutPanel rows)
    {
        rows.ColumnCount = 1; rows.RowCount = 0; rows.AutoSize = true; rows.AutoSizeMode = AutoSizeMode.GrowAndShrink;
        rows.Margin = Padding.Empty; rows.Padding = Padding.Empty; rows.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
    }
    private void ResizeRows() { content.PerformLayout(); }
    private void FitHeightToContent()
    {
        if (!autoFitHeight || fittingHeight || !IsHandleCreated || !Visible || WindowState != FormWindowState.Normal) return;
        fittingHeight = true;
        try
        {
            var area = Screen.FromControl(this).WorkingArea;
            var chrome = Height - ClientSize.Height;
            var minimum = Math.Max(1, MinimumSize.Height - chrome);
            var maximum = Math.Max(minimum, area.Height - chrome - LogicalToDeviceUnits(32));
            // 收起滚动条后内容宽度可能变化，再测量一次以兼顾中文提示换行。
            for (int pass = 0; pass < 2; pass++)
            {
                content.PerformLayout();
                var preferred = content.GetPreferredSize(new Size(viewport.ClientSize.Width, 0)).Height;
                var height = Math.Clamp(preferred, minimum, maximum);
                if (ClientSize.Height == height) break;
                ClientSize = new Size(ClientSize.Width, height);
            }
            Top = Math.Clamp(Top, area.Top, Math.Max(area.Top, area.Bottom - Height));
        }
        finally { fittingHeight = false; }
    }
    private void UpdateMinimumWindowSize()
    {
        var area = Screen.FromControl(this).WorkingArea;
        var minimum = SizeFromClientSize(new Size(LogicalToDeviceUnits(480), LogicalToDeviceUnits(440)));
        MinimumSize = new Size(Math.Min(minimum.Width, Math.Max(1, area.Width - LogicalToDeviceUnits(32))),
            Math.Min(minimum.Height, Math.Max(1, area.Height - LogicalToDeviceUnits(32))));
    }
    private static string Compact(double value) => value >= 1e9 ? $"{value / 1e9:F1}B" : value >= 1e6 ? $"{value / 1e6:F1}M" : value >= 1e3 ? $"{value / 1e3:F1}K" : value.ToString("N0");
    private void ShowWindow() { Show(); WindowState = FormWindowState.Normal; FitHeightToContent(); Activate(); }
    private void Exit() { quitting = true; Close(); }
    protected override void WndProc(ref Message m) { if (m.Msg == 0x804D) { Exit(); return; } base.WndProc(ref m); }

    private void LoadCached()
    {
        try
        {
            key = CredentialStore.Load();
            if (key != null && File.Exists(ApiCache))
            {
                var saved = JsonSerializer.Deserialize<ApiSnapshot>(File.ReadAllText(ApiCache));
                if (saved is { Valid: true } && saved.KeyFingerprint == ApiBilling.Fingerprint(key))
                    { snapshot = saved; lastAttempt = saved.FetchedAt; }
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException or InvalidDataException)
        { apiError = "监控设置或缓存不可用，请在设置中检查 API Key。"; }
        if (File.Exists(LocalCache))
        {
            try { using var doc = JsonDocument.Parse(File.ReadAllText(LocalCache)); RenderLocal(doc.RootElement); }
            catch (Exception ex) when (ex is IOException or JsonException or KeyNotFoundException) { localState.Text = "本地缓存不可用，正在重新统计。"; }
        }
        RenderRemote();
    }
    private void RenderRemote()
    {
        var today = snapshot?.DayStart == ApiBilling.DayStart(DateTimeOffset.UtcNow) ? snapshot : null;
        apiValues[0].Text = today == null ? "—" : (today.TodayComplete ? "" : "≥") + ApiBilling.Money(today.TodayUSD);
        apiNotes[0].Text = today?.TodayComplete == true ? "北京时间零点起" : "已确认下限";
        var recordedPlan = snapshot?.RecordedPlan;
        var planNote = recordedPlan != null && snapshot != null ? "刷新 " + ApiBilling.Time(snapshot.FetchedAt) : snapshot?.PlanError ?? "等待套餐消费记录";
        apiValues[1].Text = recordedPlan is { } p ? ApiBilling.Money(p.UsedUSD) : "—";
        apiNotes[1].Text = planNote;
        apiValues[2].Text = recordedPlan is { } r ? ApiBilling.Money(r.RemainingUSD) : "—";
        apiNotes[2].Text = planNote;
        apiValues[3].Text = snapshot?.AccountBalanceUSD is { } balance ? ApiBilling.Money(balance) : "—";
        apiNotes[3].Text = snapshot?.AccountError != null ? snapshot.AccountBalanceUSD != null ? "充值余额 · 上次查询" : "充值余额暂时无法更新" : "账户充值余额";
        apiValues[4].Text = snapshot?.Cycle is { } cycle ? $"第 {cycle.Week} / 4 周" : "—";
        var cycleDay = ApiBilling.DayNumber(snapshot?.Cycle);
        apiNotes[4].Text = cycleDay is >= 1 and <= 7 ? $"第 {cycleDay} 天 · 4周循环" : cycleDay > 7 ? "等待满额恢复" :
            snapshot?.Cycle?.LastResetAt is { } reset ? "满额恢复 " + reset.ToOffset(TimeSpan.FromHours(8)).ToString("MM-dd HH:mm", CultureInfo.InvariantCulture) :
            snapshot?.Cycle != null ? "当前周起算 · 4周循环" : "等待套餐账单";
        var remainingDays = ApiBilling.RemainingCycleDays(snapshot?.Cycle);
        apiValues[5].Text = remainingDays is { } daysLeft ? $"{daysLeft} 天" : "—";
        var estimatedEnd = ApiBilling.CycleEstimatedEndDate(snapshot?.Cycle);
        apiNotes[5].Text = estimatedEnd is { } end ? "预计到期：" + end.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture) : "等待周期校准";
        apiTitle.Text = "● api-top.com" + (snapshot == null ? "" : " · " + snapshot.KeyName);
        apiTitle.ForeColor = apiError != null || snapshot?.PlanError != null ? Color.Orange : snapshot == null ? Secondary : Color.MediumSeaGreen;
        remoteRefresh.Enabled = key != null && !remoteBusy;

    }
    private async Task RefreshRemote(bool force = false)
    {
        if (key == null || remoteBusy || (!force && DateTimeOffset.UtcNow - lastAttempt < ApiRefreshPolicy.Interval)) return;
        lastAttempt = DateTimeOffset.UtcNow; remoteBusy = true; apiError = null; var revision = generation;
        var savedKey = key; var previous = snapshot; request?.Dispose(); request = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        var cancellation = request.Token; RenderRemote();
        try
        {
            var gate = new ApiTriggerGate(support);
            var fresh = await ApiClient.Refresh(savedKey, previous, cancellation, at => gate.Reserve(savedKey, at));
            if (cancellation.IsCancellationRequested || revision != generation || IsDisposed) return;
            snapshot = fresh; lastAttempt = fresh.FetchedAt; Directory.CreateDirectory(support);
            var temporary = ApiCache + ".tmp"; await File.WriteAllTextAsync(temporary, JsonSerializer.Serialize(fresh), cancellation); File.Move(temporary, ApiCache, true);
        }
        catch (OperationCanceledException) { if (!cancellation.IsCancellationRequested) apiError = "平台查询超时，保留上次结果。"; }
        catch (InvalidDataException ex) { apiError = ex.Message; }
        catch (Exception ex) when (ex is HttpRequestException or IOException or UnauthorizedAccessException or JsonException or KeyNotFoundException or FormatException or InvalidOperationException)
        { apiError = "账单暂时无法更新，保留上次结果。"; }
        finally { if (revision == generation) {
            remoteBusy = false;
            if (!IsDisposed && !lifetime.IsCancellationRequested) RenderRemote();
        } }
    }
    private Form CreateSettingsDialog()
    {
        var dialog = new Form();
        dialog.SuspendLayout();
        dialog.AutoScaleDimensions = new SizeF(96, 96); dialog.AutoScaleMode = AutoScaleMode.Dpi;
        dialog.Text = "API 监控设置"; dialog.BackColor = Background; dialog.ForeColor = TextColor;
        dialog.ClientSize = new Size(450, 164); dialog.FormBorderStyle = FormBorderStyle.FixedDialog;
        dialog.StartPosition = FormStartPosition.CenterParent; dialog.MinimizeBox = false; dialog.MaximizeBox = false;
        dialog.HandleCreated += (_, _) => NativeTheme.ApplyDarkTitleBar(dialog.Handle);
        var body = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(18), ColumnCount = 1, RowCount = 3 };
        body.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        body.RowStyles.Add(new RowStyle(SizeType.AutoSize)); body.RowStyles.Add(new RowStyle(SizeType.Percent, 100)); body.RowStyles.Add(new RowStyle(SizeType.Absolute, 34));
        var label = Label("api-top.com · 密钥保存在 Windows 凭据管理器", 10, Secondary);
        label.Dock = DockStyle.Fill; label.Margin = new Padding(0, 0, 0, 10);
        var input = new TextBox { Dock = DockStyle.Top, UseSystemPasswordChar = true,
            PlaceholderText = "新的 API Key（留空保留当前密钥）", Margin = new Padding(0, 0, 0, 8) };
        var save = Button("保存并刷新", (_, _) => {
            if (string.IsNullOrWhiteSpace(input.Text)) { dialog.DialogResult = DialogResult.Cancel; return; }
            try { dialog.Tag = CredentialStore.Save(input.Text); input.Clear(); dialog.DialogResult = DialogResult.OK; }
            catch (Exception ex) when (ex is IOException or InvalidDataException) { MessageBox.Show(dialog, ex.Message, "无法保存设置", MessageBoxButtons.OK, MessageBoxIcon.Warning); }
        });
        var cancel = Button("取消", (_, _) => { dialog.DialogResult = DialogResult.Cancel; });
        var buttons = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 3, RowCount = 1, Margin = Padding.Empty };
        buttons.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); buttons.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 120)); buttons.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 80));
        buttons.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        save.Dock = DockStyle.Fill; cancel.Dock = DockStyle.Fill;
        buttons.Controls.Add(save, 1, 0); buttons.Controls.Add(cancel, 2, 0);
        body.Controls.Add(label, 0, 0); body.Controls.Add(input, 0, 1); body.Controls.Add(buttons, 0, 2);
        dialog.Controls.Add(body); dialog.AcceptButton = save; dialog.CancelButton = cancel;
        dialog.FormClosed += (_, _) => input.Clear();
        dialog.ResumeLayout(true);
        return dialog;
    }
    private void ShowSettings()
    {
        using var dialog = CreateSettingsDialog();
        if (dialog.ShowDialog(this) == DialogResult.OK && dialog.Tag is string next)
        {
            var retained = snapshot is { Valid: true } && snapshot.KeyFingerprint == ApiBilling.Fingerprint(next) ? snapshot : null;
            request?.Cancel(); generation++; remoteBusy = false; key = next;
            snapshot = retained;
            apiError = null; lastAttempt = DateTimeOffset.MinValue;
            RenderRemote(); _ = RefreshRemote(true);
        }
        dialog.Tag = null;
    }

    private async Task RefreshLocal(bool force = false)
    {
        if (localBusy || lifetime.IsCancellationRequested) return;
        var file = new FileInfo(queue); var stamp = file.Exists ? $"{file.Length}:{file.LastWriteTimeUtc.Ticks}:{DateTime.Today:yyyy-MM-dd}" : "missing:" + DateTime.Today.ToString("yyyy-MM-dd");
        var now = DateTimeOffset.UtcNow;
        if (!LocalStatisticsWorker.ShouldRefresh(stamp, localStamp, now, lastLocalAttempt, force)) return;
        lastLocalAttempt = now;
        localBusy = true;
        try
        {
            Directory.CreateDirectory(support);
            var resources = Path.Combine(AppContext.BaseDirectory, "Resources");
            var start = LocalStatisticsWorker.CreateStartInfo(resources, queue, Path.Combine(support, "usage.sqlite"), Path.Combine(support, "local-collector"));
            using var child = Process.Start(start) ?? throw new IOException("无法启动统计组件。"); worker = child;
            var output = child.StandardOutput.ReadToEndAsync(lifetime.Token); var stderr = child.StandardError.ReadToEndAsync(lifetime.Token);
            await child.WaitForExitAsync(lifetime.Token); var json = await output; await stderr;
            if (child.ExitCode != 0 || json.Length > 8 * 1024 * 1024) throw new IOException("统计组件返回异常。");
            if (lifetime.IsCancellationRequested || IsDisposed) return;
            using var doc = JsonDocument.Parse(json); RenderLocal(doc.RootElement); localStamp = stamp;
            await File.WriteAllTextAsync(LocalCache + ".tmp", json, lifetime.Token); File.Move(LocalCache + ".tmp", LocalCache, true);
        }
        catch (OperationCanceledException) { localState.Text = "统计已取消。"; }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException or KeyNotFoundException or System.ComponentModel.Win32Exception or InvalidOperationException)
        { if (!IsDisposed && !lifetime.IsCancellationRequested) localState.Text = "本机统计未完成，保留上次结果。"; }
        finally { worker = null; localBusy = false; }
    }
    private void RenderLocal(JsonElement data)
    {
        var names = new[] { "today", "month", "all" };
        for (int i = 0; i < 3; i++)
        {
            var item = data.GetProperty(names[i]); localValues[i].Text = Compact(item.GetProperty("tokens").GetDouble());
            var cost = item.GetProperty("cost_usd").GetDouble(); var unpriced = item.GetProperty("unpriced_tokens").GetDouble();
            localCosts[i].Text = $"${cost:F2}" + (unpriced > 0 ? " · 部分估算" : "");
        }
        void Rows(TableLayoutPanel target, string property, bool daily)
        {
            target.SuspendLayout();
            foreach (Control control in target.Controls.Cast<Control>().ToArray()) control.Dispose();
            target.Controls.Clear(); target.RowStyles.Clear(); target.RowCount = 0;
            foreach (var row in data.GetProperty(property).EnumerateArray())
            {
                var name = row.GetProperty(daily ? "day" : "model").GetString() ?? "未知"; if (daily && name.Length >= 5) name = name[^5..];
                var panel = new TableLayoutPanel { ColumnCount = 2, RowCount = 1, Dock = DockStyle.Fill, Margin = Padding.Empty, Padding = Padding.Empty };
                panel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); panel.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
                var left = Label(name, 9, Secondary); left.Dock = DockStyle.Fill; left.AutoSize = false; left.AutoEllipsis = true; left.TextAlign = ContentAlignment.MiddleLeft;
                var right = Label($"{Compact(row.GetProperty("tokens").GetDouble())} · ${row.GetProperty("cost_usd").GetDouble():F2}", 9, Secondary);
                right.Dock = DockStyle.Fill; right.AutoSize = true; right.TextAlign = ContentAlignment.MiddleRight;
                panel.Controls.Add(left, 0, 0); panel.Controls.Add(right, 1, 0);
                var index = target.RowCount++; target.RowStyles.Add(new RowStyle(SizeType.Absolute, LogicalToDeviceUnits(23)));
                target.Controls.Add(panel, 0, index);
            }
            if (target.Controls.Count == 0) {
                target.RowCount = 1; target.RowStyles.Add(new RowStyle(SizeType.AutoSize));
                target.Controls.Add(Label("暂无记录", 9, Secondary), 0, 0);
            }
            target.ResumeLayout(true);
        }
        Rows(days, "days", true); Rows(models, "models", false);
        localState.Text = data.TryGetProperty("warning", out var warning) ? warning.GetString() ?? "" : "";
        var updated = data.GetProperty("queue_updated_at");
        collected.Text = updated.ValueKind == JsonValueKind.String && DateTimeOffset.TryParse(updated.GetString(), out var date)
            ? "最后采集：" + date.ToLocalTime().ToString("MM-dd HH:mm:ss") : "最后采集：暂无记录";
        ResizeRows();
        FitHeightToContent();
    }
}
