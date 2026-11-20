using System.Diagnostics;
using System.Text;

namespace TokenTrackerLite;

internal static class LocalStatisticsWorker
{
    internal static bool ShouldRefresh(string queueStamp, string previousQueueStamp, DateTimeOffset now,
        DateTimeOffset lastAttempt, bool force = false) => force || queueStamp != previousQueueStamp || now - lastAttempt >= TimeSpan.FromSeconds(60);

    internal static ProcessStartInfo CreateStartInfo(string resources, string queue, string database, string? collectStateDir = null)
    {
        // Node 的 JSON 和中文诊断始终输出 UTF-8，不能使用 Windows 本地代码页解码。
        var start = new ProcessStartInfo(Path.Combine(resources, "node.exe")) {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8
        };
        foreach (var argument in new[] { "--no-warnings", Path.Combine(resources, "TokenTrackerLite", "queue-store.cjs"),
            "--queue", queue, "--database", database }) start.ArgumentList.Add(argument);
        if (collectStateDir != null)
        {
            start.ArgumentList.Add("--collect-state-dir");
            start.ArgumentList.Add(collectStateDir);
        }
        return start;
    }
}
