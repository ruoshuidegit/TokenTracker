using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

namespace TokenTrackerLite;

internal sealed class MetricCard : TableLayoutPanel
{
    public MetricCard()
    {
        ColumnCount = 1; RowCount = 3; BackColor = Color.FromArgb(30, 30, 30);
        DoubleBuffered = true; ResizeRedraw = true;
    }
    protected override void OnPaintBackground(PaintEventArgs e)
    {
        e.Graphics.Clear(BackColor);
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        var bounds = new RectangleF(0.5f, 0.5f, Math.Max(0, Width - 1), Math.Max(0, Height - 1));
        var radius = LogicalToDeviceUnits(9);
        using var path = new GraphicsPath();
        path.AddRoundedRectangle(bounds, radius);
        using var brush = new SolidBrush(Color.FromArgb(43, 43, 43));
        using var border = new Pen(Color.FromArgb(56, 56, 56));
        e.Graphics.FillPath(brush, path); e.Graphics.DrawPath(border, path);
    }
}

internal static class RoundedPath
{
    internal static void AddRoundedRectangle(this GraphicsPath path, RectangleF bounds, float radius)
    {
        var diameter = Math.Min(radius * 2, Math.Min(bounds.Width, bounds.Height));
        if (diameter <= 0) return;
        path.AddArc(bounds.Left, bounds.Top, diameter, diameter, 180, 90);
        path.AddArc(bounds.Right - diameter, bounds.Top, diameter, diameter, 270, 90);
        path.AddArc(bounds.Right - diameter, bounds.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(bounds.Left, bounds.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
    }
}

internal sealed class MonitorButton : Button
{
    public MonitorButton() { FlatStyle = FlatStyle.Flat; FlatAppearance.BorderSize = 0; UseVisualStyleBackColor = false; }
    protected override void OnPaint(PaintEventArgs e)
    {
        // 原生 Flat 按钮的禁用文字会变成黑色，深色面板中使用相同的语义灰。
        e.Graphics.Clear(BackColor);
        if (Enabled && ClientRectangle.Contains(PointToClient(Cursor.Position)))
        {
            using var brush = new SolidBrush(Color.FromArgb(48, 48, 48));
            e.Graphics.FillRectangle(brush, ClientRectangle);
        }
        TextRenderer.DrawText(e.Graphics, Text, Font, ClientRectangle,
            Enabled ? ForeColor : Color.FromArgb(130, 130, 136),
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
        if (Focused && ShowFocusCues) ControlPaint.DrawFocusRectangle(e.Graphics, Rectangle.Inflate(ClientRectangle, -3, -3));
    }
}

internal static class NativeTheme
{
    [DllImport("dwmapi.dll")] private static extern int DwmSetWindowAttribute(IntPtr handle, int attribute, ref int value, int size);
    internal static void ApplyDarkTitleBar(IntPtr handle)
    {
        int enabled = 1;
        _ = DwmSetWindowAttribute(handle, 20, ref enabled, sizeof(int));
    }
}
