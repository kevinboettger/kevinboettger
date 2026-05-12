[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$OutPath,
    [int]$Seconds = 1800
)

# DEBUG_VIEW_v1: in-process replacement for Sysinternals DbgView.
# Creates the DBWIN_BUFFER section + DBWIN_DATA_READY / DBWIN_BUFFER_READY events,
# then reads OutputDebugString messages from any same-user process (e.g. UE4Editor
# + the Immerse plug-in DLL) and appends them to $OutPath. No external tool, no
# admin prompt, no kernel driver. Replace at most one running monitor at a time
# (close any DbgView / DebugView++ first).

$ErrorActionPreference = 'Continue'

$src = @'
using System;
using System.IO;
using System.IO.MemoryMappedFiles;
using System.Runtime.InteropServices;
using System.Text;

public static class DebugMonitor {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateEventW(IntPtr lpEventAttributes, bool bManualReset, bool bInitialState, string lpName);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetEvent(IntPtr hEvent);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr hObject);

    public static int Run(string outPath, int maxSeconds) {
        IntPtr dataReady = CreateEventW(IntPtr.Zero, false, false, "DBWIN_DATA_READY");
        if (dataReady == IntPtr.Zero) {
            File.AppendAllText(outPath, "ERROR: CreateEvent DBWIN_DATA_READY failed: " + Marshal.GetLastWin32Error() + Environment.NewLine);
            return -1;
        }
        IntPtr bufferReady = CreateEventW(IntPtr.Zero, false, true, "DBWIN_BUFFER_READY");
        if (bufferReady == IntPtr.Zero) {
            File.AppendAllText(outPath, "ERROR: CreateEvent DBWIN_BUFFER_READY failed: " + Marshal.GetLastWin32Error() + Environment.NewLine);
            CloseHandle(dataReady);
            return -2;
        }

        MemoryMappedFile mmf;
        try {
            mmf = MemoryMappedFile.CreateOrOpen("DBWIN_BUFFER", 4096L, MemoryMappedFileAccess.ReadWrite);
        } catch (Exception ex) {
            File.AppendAllText(outPath, "ERROR: open DBWIN_BUFFER failed: " + ex.Message + Environment.NewLine);
            CloseHandle(dataReady);
            CloseHandle(bufferReady);
            return -3;
        }

        using (mmf)
        using (var view = mmf.CreateViewAccessor(0, 4096, MemoryMappedFileAccess.ReadWrite))
        using (var sw = new StreamWriter(outPath, false, Encoding.UTF8) { AutoFlush = true }) {
            sw.WriteLine("[" + DateTime.Now.ToString("o") + "] DebugMonitor start, maxSeconds=" + maxSeconds);
            DateTime endAt = DateTime.UtcNow.AddSeconds(maxSeconds);
            byte[] buf = new byte[4092];
            int lines = 0;
            while (DateTime.UtcNow < endAt) {
                uint w = WaitForSingleObject(dataReady, 500);
                if (w != 0) { continue; }
                int pid = view.ReadInt32(0);
                view.ReadArray(4, buf, 0, buf.Length);
                int len = 0;
                while (len < buf.Length && buf[len] != 0) len++;
                string msg = Encoding.ASCII.GetString(buf, 0, len).TrimEnd('\r', '\n');
                sw.WriteLine("[" + DateTime.Now.ToString("o") + "] [pid=" + pid + "] " + msg);
                lines++;
                SetEvent(bufferReady);
            }
            sw.WriteLine("[" + DateTime.Now.ToString("o") + "] DebugMonitor exit, lines=" + lines);
        }
        CloseHandle(dataReady);
        CloseHandle(bufferReady);
        return 0;
    }
}
'@

Add-Type -TypeDefinition $src -Language CSharp

$dir = Split-Path -Parent $OutPath
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
[DebugMonitor]::Run($OutPath, $Seconds) | Out-Null
