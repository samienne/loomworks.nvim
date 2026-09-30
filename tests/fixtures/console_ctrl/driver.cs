// Console-interrupt driver for the Windows tests in tests/standalone.
//
//   driver.exe <event> <marker> <command line...>
//
// Runs the command line in a NEW console, waits until the program under test
// writes <marker>.started, then sends <event> (0 = CTRL_C_EVENT, 1 =
// CTRL_BREAK_EVENT) to that console, the way a key press does. It reports in
// <marker>.report, as key=value lines:
//   cleanup=<what the program wrote to <marker>, or empty>
//   exited=1|0        whether the root process ended within 5 s
//   code=<n>          its exit code (when it ended)
//   prompt=1|0        whether the console shows "Terminate batch job (Y/N)?"
// followed by the console's text. A root still running is then killed.
using System;
using System.IO;
using System.Text;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

class Driver {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct STARTUPINFO {
    public int cb; public string reserved, desktop, title;
    public int x, y, xSize, ySize, xChars, yChars, fill, flags;
    public short show, reserved2; public IntPtr reserved3, stdIn, stdOut, stdErr;
  }
  [StructLayout(LayoutKind.Sequential)]
  struct PROCESS_INFORMATION { public IntPtr process, thread; public int pid, tid; }
  [StructLayout(LayoutKind.Sequential)] struct COORD { public short X, Y; }
  [StructLayout(LayoutKind.Sequential)]
  struct CSBI { public COORD size, cursor; public short attr, l, t, r, b; public COORD max; }
  delegate bool Handler(uint ev);

  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  static extern bool CreateProcess(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit,
    uint flags, IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
  [DllImport("kernel32.dll")] static extern bool FreeConsole();
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool AttachConsole(int pid);
  [DllImport("kernel32.dll")] static extern bool SetConsoleCtrlHandler(IntPtr h, bool add);
  [DllImport("kernel32.dll", EntryPoint = "SetConsoleCtrlHandler")]
  static extern bool AddCtrlHandler(Handler h, bool add);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool GenerateConsoleCtrlEvent(uint ev, uint group);
  [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
  [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr h, out uint code);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr sa, uint disp, uint flags, IntPtr tmpl);
  [DllImport("kernel32.dll")] static extern bool GetConsoleScreenBufferInfo(IntPtr h, out CSBI info);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
  static extern bool ReadConsoleOutputCharacter(IntPtr h, StringBuilder buf, uint len, COORD at, out uint read);

  static Handler ignore = ev => true;

  static string Screen() {
    IntPtr h = CreateFile("CONOUT$", 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
    CSBI info;
    if (!GetConsoleScreenBufferInfo(h, out info)) return "";
    var sb = new StringBuilder();
    for (short y = 0; y <= info.cursor.Y; y++) {
      var line = new StringBuilder(info.size.X + 1); uint n;
      ReadConsoleOutputCharacter(h, line, (uint)info.size.X, new COORD { X = 0, Y = y }, out n);
      string s = line.ToString();
      if (s.Length > n) s = s.Substring(0, (int)n);
      sb.Append(s.TrimEnd()).Append('\n');
    }
    return sb.ToString();
  }

  static int Main(string[] a) {
    uint ev = uint.Parse(a[0]);
    string marker = a[1];
    string cmdline = string.Join(" ", a, 2, a.Length - 2);
    File.Delete(marker); File.Delete(marker + ".started"); File.Delete(marker + ".report");
    Environment.SetEnvironmentVariable("FAKE_MARKER", marker);
    // A parent that ignores Ctrl-C passes that on; the program under test must
    // get the console's default Ctrl-C handling, as from an interactive shell.
    SetConsoleCtrlHandler(IntPtr.Zero, false);
    var si = new STARTUPINFO(); si.cb = Marshal.SizeOf(si); si.flags = 1; si.show = 7;
    PROCESS_INFORMATION pi;
    const uint CREATE_NEW_CONSOLE = 0x10;
    if (!CreateProcess(null, new StringBuilder(cmdline), IntPtr.Zero, IntPtr.Zero, false,
        CREATE_NEW_CONSOLE, IntPtr.Zero, null, ref si, out pi)) {
      File.WriteAllText(marker + ".report", "error=CreateProcess " + Marshal.GetLastWin32Error() + "\n");
      return 2;
    }
    for (int k = 0; k < 300 && !File.Exists(marker + ".started"); k++) Thread.Sleep(100);
    Thread.Sleep(300);
    FreeConsole();
    string err = "";
    if (!AttachConsole(pi.pid)) err = "AttachConsole " + Marshal.GetLastWin32Error();
    // The driver itself shares the console now: it must survive the event.
    SetConsoleCtrlHandler(IntPtr.Zero, true);
    AddCtrlHandler(ignore, true);
    if (err == "" && !GenerateConsoleCtrlEvent(ev, 0)) err = "GenerateConsoleCtrlEvent " + Marshal.GetLastWin32Error();
    for (int k = 0; k < 50 && !File.Exists(marker); k++) Thread.Sleep(100);
    bool exited = WaitForSingleObject(pi.process, 5000) == 0;
    uint code; GetExitCodeProcess(pi.process, out code);
    string screen = Screen();
    FreeConsole();
    if (!exited) {
      var kill = new ProcessStartInfo(Environment.GetEnvironmentVariable("SystemRoot") + "\\System32\\taskkill.exe",
        "/F /T /PID " + pi.pid) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true };
      Process.Start(kill).WaitForExit();
    }
    var r = new StringBuilder();
    if (err != "") r.Append("error=").Append(err).Append('\n');
    r.Append("cleanup=").Append(File.Exists(marker) ? File.ReadAllText(marker).Trim() : "").Append('\n');
    r.Append("exited=").Append(exited ? "1" : "0").Append('\n');
    if (exited) r.Append("code=").Append((int)code).Append('\n');
    r.Append("prompt=").Append(screen.Contains("Terminate batch job") ? "1" : "0").Append('\n');
    r.Append("screen:\n").Append(screen);
    File.WriteAllText(marker + ".report", r.ToString());
    return 0;
  }
}
