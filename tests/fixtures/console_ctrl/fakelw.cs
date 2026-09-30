// Stand-in for an lw host in the Windows console-interrupt tests (tests/standalone).
// Like lw (libuv's sigint/sigbreak watchers) it handles CTRL_C_EVENT and
// CTRL_BREAK_EVENT: "cleans up" (writes %FAKE_MARKER%) and exits 130. It
// announces itself in %FAKE_MARKER%.started, then waits (at most 30 s).
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

class FakeLw {
  delegate bool Handler(uint ev);
  [DllImport("kernel32.dll")] static extern bool SetConsoleCtrlHandler(Handler h, bool add);
  static Handler keep;

  static int Main(string[] args) {
    string marker = Environment.GetEnvironmentVariable("FAKE_MARKER");
    keep = ev => {
      if (ev != 0 && ev != 1) return false;
      new Thread(() => {
        Thread.Sleep(300);
        File.WriteAllText(marker, "ev=" + ev);
        Environment.Exit(130);
      }).Start();
      return true;
    };
    SetConsoleCtrlHandler(keep, true);
    File.WriteAllText(marker + ".started", "started");
    Thread.Sleep(30000);
    return 0;
  }
}
