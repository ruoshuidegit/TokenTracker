using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;

namespace TokenTrackerLite;

internal static class CredentialStore
{
    private const string Target = "TokenTrackerLite:api-top.com";
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct Credential
    {
        public uint Flags, Type;
        public string TargetName, Comment;
        public FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist, AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias, UserName;
    }
    [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool Read(string target, uint type, uint flags, out IntPtr credential);
    [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool Write(ref Credential credential, uint flags);
    [DllImport("advapi32.dll")] private static extern void CredFree(IntPtr buffer);

    public static string? Load()
    {
        if (!Read(Target, 1, 0, out var pointer))
        {
            if (Marshal.GetLastWin32Error() == 1168) return null;
            throw new IOException("无法读取 Windows 凭据管理器，请重新设置 API Key。");
        }
        try
        {
            var credential = Marshal.PtrToStructure<Credential>(pointer);
            if (credential.CredentialBlobSize > 256) throw new InvalidDataException("监控密钥格式异常。");
            var data = new byte[credential.CredentialBlobSize];
            Marshal.Copy(credential.CredentialBlob, data, 0, data.Length);
            return ApiBilling.ValidateKey(Encoding.UTF8.GetString(data));
        }
        finally { CredFree(pointer); }
    }
    public static string Save(string input)
    {
        var key = ApiBilling.ValidateKey(input); var bytes = Encoding.UTF8.GetBytes(key);
        var pointer = Marshal.AllocHGlobal(bytes.Length);
        try
        {
            Marshal.Copy(bytes, 0, pointer, bytes.Length);
            var credential = new Credential { Type = 1, TargetName = Target, Comment = "TokenTracker Lite API 监控密钥",
                CredentialBlobSize = (uint)bytes.Length, CredentialBlob = pointer, Persist = 2,
                TargetAlias = "", UserName = "api-top.com" };
            if (!Write(ref credential, 0)) throw new IOException("无法保存到 Windows 凭据管理器。");
            return key;
        }
        finally { Marshal.Copy(new byte[bytes.Length], 0, pointer, bytes.Length); Marshal.FreeHGlobal(pointer); Array.Clear(bytes); }
    }
}
