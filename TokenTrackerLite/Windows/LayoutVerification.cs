using System.Drawing.Imaging;
using System.Diagnostics;
using System.Text.Json;

namespace TokenTrackerLite;

// 只在显式验证参数下使用模拟账单；不读取用户凭据、队列或访问网络。
internal sealed partial class TrackerWindow
{
    internal void LoadLayoutFixture()
    {
        var now = DateTimeOffset.UtcNow;
        snapshot = new ApiSnapshot(1, "layout-fixture", "测试监控", ApiBilling.DayStart(now), 12.3456m, false, [], 123.4567m, now,
            new PlanSnapshot("月用无忧", 11.8077m, 16.9423m, 28.75m, now))
            { PlanSource = "consumption_log", AccountBalanceUSD = 123.4567m, Cycle = new CycleState(1, 1, 1, "月用无忧", 14375000, 5903850, 8471150, now, "layout-fixture",
                WeekStartedAt: ApiBilling.DayStart(now).AddDays(-3)) };
        RenderRemote();
        object Amount(double tokens, double cost, double unpriced = 0) => new { tokens, cost_usd = cost, unpriced_tokens = unpriced };
        var fixture = new {
            today = Amount(636100000, 124.86), month = Amount(15500000000, 6300.60), all = Amount(60700000000, 28563.17, 10100000),
            days = Enumerable.Range(0, 7).Select(i => new { day = DateTime.Today.AddDays(i - 6).ToString("yyyy-MM-dd"), tokens = 1234000000, cost_usd = 123.45 }),
            models = new[] { "gpt-6.1-sol", "gpt-6-astra", "DeepSeek-V4.1-Flash", "GLM-5.3", "gemini-4-argon-trial" }
                .Select(model => new { model, tokens = 1234000000, cost_usd = 1234.56 }),
            queue_updated_at = now.ToString("O")
        };
        using var json = JsonDocument.Parse(JsonSerializer.Serialize(fixture));
        RenderLocal(json.RootElement);
    }

    internal async Task LoadMissingQueueFixtureAsync()
    {
        var directory = Path.Combine(Path.GetTempPath(), "TokenTrackerLite-encoding-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            var resources = Path.Combine(AppContext.BaseDirectory, "Resources");
            var start = LocalStatisticsWorker.CreateStartInfo(resources, Path.Combine(directory, "missing-queue.jsonl"), Path.Combine(directory, "usage.sqlite"));
            using var child = Process.Start(start) ?? throw new IOException("测试统计组件启动失败。");
            var output = child.StandardOutput.ReadToEndAsync();
            var stderr = child.StandardError.ReadToEndAsync();
            await child.WaitForExitAsync();
            var json = await output; await stderr;
            if (child.ExitCode != 0) throw new InvalidDataException("测试统计组件未正常完成。");
            using var document = JsonDocument.Parse(json);
            if (document.RootElement.GetProperty("warning").GetString() != "尚未找到采集队列，显示上次保存的数据")
                throw new InvalidDataException("统计进程的 UTF-8 中文提示解码失败。");
            snapshot = null; RenderRemote(); RenderLocal(document.RootElement);
        }
        finally { Directory.Delete(directory, recursive: true); }
    }

    internal object InspectLayout(Form? target = null, bool checkBottomGap = false)
    {
        var form = target ?? this;
        var failures = new List<string>();
        var labels = new List<object>();
        if (form.Text == "API 监控设置" && Math.Abs(form.ClientSize.Width - 450 * form.DeviceDpi / 96d) > 1)
            failures.Add("设置窗口未按 DPI 设计尺寸缩放");
        var bottomGap = target == null ? viewport.ClientSize.Height - content.Height : 0;
        if (checkBottomGap && bottomGap > LogicalToDeviceUnits(4)) failures.Add("内容下方存在多余空白");
        void Visit(Control parent)
        {
            foreach (Control control in parent.Controls)
            {
                if (control is System.Windows.Forms.Label label && label.Visible && label.Text.Length > 0)
                {
                    var measured = TextRenderer.MeasureText(label.Text, label.Font, Size.Empty,
                        TextFormatFlags.SingleLine | TextFormatFlags.NoPadding);
                    var bounds = label.Bounds;
                    labels.Add(new { label.Text, fontPoints = label.Font.SizeInPoints, bounds.X, bounds.Y, bounds.Width, bounds.Height,
                        measuredWidth = measured.Width, measuredHeight = measured.Height });
                    if (bounds.Height + 2 < measured.Height) failures.Add("文字高度不足：" + label.Text);
                    if (label.Parent != null && (bounds.Right > label.Parent.ClientSize.Width + 2 || bounds.Bottom > label.Parent.ClientSize.Height + 2))
                        failures.Add("文字超出容器：" + label.Text);
                    foreach (Control sibling in parent.Controls)
                    {
                        if (sibling == label || sibling is not System.Windows.Forms.Label || sibling.Text.Length == 0) continue;
                        var intersection = Rectangle.Intersect(bounds, sibling.Bounds);
                        if (intersection.Width > 1 && intersection.Height > 1) failures.Add("文字重叠：" + label.Text + " / " + sibling.Text);
                    }
                    if (label.Text.Contains("TokenTracker Lite") && measured.Width > label.ClientSize.Width)
                        failures.Add("标题无法单行完整显示");
                }
                if (control is Button button && button.Visible)
                {
                    var size = TextRenderer.MeasureText(button.Text, button.Font, Size.Empty, TextFormatFlags.SingleLine | TextFormatFlags.NoPadding);
                    if (size.Width > button.ClientSize.Width || size.Height > button.ClientSize.Height)
                        failures.Add("按钮文字无法完整显示：" + button.Text);
                }
                if (control is TextBox field && field.Height < field.PreferredHeight)
                    failures.Add("设置输入框高度不足");
                Visit(control);
            }
        }
        Visit(form);
        return new { dpi = form.DeviceDpi, clientWidth = form.ClientSize.Width, clientHeight = form.ClientSize.Height,
            autoScaleDimensions = new { form.AutoScaleDimensions.Width, form.AutoScaleDimensions.Height }, bottomGap, labels, failures };
    }
}

internal static class LayoutVerification
{
    internal static void Run(string directory)
    {
        Directory.CreateDirectory(directory);
        using var form = new TrackerWindow(layoutVerification: true);
        form.Shown += (_, _) => form.BeginInvoke(new Action(async () => {
            try
            {
                form.LoadLayoutFixture();
                form.PerformLayout();
                var results = new List<object>();
                await form.LoadMissingQueueFixtureAsync();
                form.PerformLayout();
                var emptyHeight = form.ClientSize.Height;
                results.Add(form.InspectLayout(checkBottomGap: true));
                using (var empty = new Bitmap(form.ClientSize.Width, form.ClientSize.Height))
                {
                    form.DrawLayoutClient(empty);
                    empty.Save(Path.Combine(directory, "missing-queue.png"), ImageFormat.Png);
                }
                form.LoadLayoutFixture(); form.PerformLayout();
                if (form.ClientSize.Height <= emptyHeight + (int)Math.Round(40 * form.DeviceDpi / 96d))
                    throw new InvalidDataException("Top 5 出现记录后，窗口未随内容增高。");
                foreach (var width in new[] { form.ClientSize.Width, (int)Math.Round(480 * form.DeviceDpi / 96d), (int)Math.Round(640 * form.DeviceDpi / 96d) })
                {
                    form.ClientSize = new Size(width, form.ClientSize.Height);
                    form.PerformLayout();
                    results.Add(form.InspectLayout(checkBottomGap: true));
                    using var bitmap = new Bitmap(form.ClientSize.Width, form.ClientSize.Height);
                    form.DrawLayoutClient(bitmap);
                    bitmap.Save(Path.Combine(directory, $"layout-{width}.png"), ImageFormat.Png);
                }
                form.Size = form.MinimumSize; form.PerformLayout();
                results.Add(form.InspectLayout());
                await form.LoadMissingQueueFixtureAsync();
                results.Add(form.InspectLayout(checkBottomGap: true));
                using var settings = form.CreateLayoutSettings();
                settings.Show(form); settings.PerformLayout();
                results.Add(form.InspectLayout(settings));
                using (var bitmap = new Bitmap(settings.ClientSize.Width, settings.ClientSize.Height))
                {
                    settings.Controls[0].DrawToBitmap(bitmap, new Rectangle(Point.Empty, settings.ClientSize));
                    bitmap.Save(Path.Combine(directory, "settings.png"), ImageFormat.Png);
                }
                settings.Close();
                var report = JsonSerializer.Serialize(results, new JsonSerializerOptions { WriteIndented = true });
                File.WriteAllText(Path.Combine(directory, "layout.json"), report);
                using var checks = JsonDocument.Parse(report);
                if (checks.RootElement.EnumerateArray().Any(x => x.GetProperty("failures").GetArrayLength() > 0)) Environment.ExitCode = 1;
            }
            catch (Exception error) { Environment.ExitCode = 1; File.WriteAllText(Path.Combine(directory, "failure.txt"), error.ToString()); }
            finally { form.CloseForVerification(); }
        }));
        Application.Run(form);
    }
}

internal sealed partial class TrackerWindow
{
    internal void DrawLayoutClient(Bitmap bitmap) { viewport.DrawToBitmap(bitmap, new Rectangle(Point.Empty, viewport.ClientSize)); }
    internal Form CreateLayoutSettings() => CreateSettingsDialog();
    internal void CloseForVerification() { quitting = true; Close(); }
}
