// "Foundry Godot Viewer.exe": double-click to start the viewer (play mode), no console window.
// Built by tools\make-launcher.ps1 with the C# compiler that ships with Windows; nothing to install.
//   "Foundry Godot Viewer.exe"          play mode (players)
//   "Foundry Godot Viewer.exe" --dev    dev mode (the GM view); other arguments go to the viewer too
// Godot is found in this order: bin\godot.exe next to the exe (portable copy), Scoop's Godot, godot.exe on PATH.
using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.Sockets;
using System.Windows.Forms;

static class FoundryGodotViewer
{
    const int ViewerPort = 8765;  // the viewer's bridge port (bridge_server.gd)

    [STAThread]
    static int Main(string[] args)
    {
        string project = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
        if (!File.Exists(Path.Combine(project, "project.godot")))
        {
            Fail("project.godot isn't next to this launcher (" + project + ").\nKeep the exe in the viewer folder.");
            return 1;
        }
        if (ViewerRunning())
        {
            Fail("The viewer is already running (port " + ViewerPort + " is in use).\nClose it first, or switch modes in it with Ctrl+`.");
            return 1;
        }
        string godot = FindGodot(project);
        if (godot == null)
        {
            Fail("Godot 4 wasn't found.\nPut godot.exe in " + Path.Combine(project, "bin") + ", or install it (scoop install godot).");
            return 1;
        }
        string extra = string.Join(" ", args.Select(Quote));
        // Our own arguments (--dev) go after "--", where the viewer reads them (OS.get_cmdline_user_args).
        var start = new ProcessStartInfo(godot, "--path " + Quote(project) + (extra.Length > 0 ? " -- " + extra : ""));
        start.UseShellExecute = false;
        start.WorkingDirectory = project;
        try
        {
            Process.Start(start);
        }
        catch (Exception e)
        {
            Fail("Couldn't start Godot (" + godot + "):\n" + e.Message);
            return 1;
        }
        return 0;
    }

    static string FindGodot(string project)
    {
        string bundled = Path.Combine(project, "bin\\godot.exe");
        if (File.Exists(bundled)) return bundled;
        // Scoop's godot.exe on PATH is a shim that keeps a console open; use the real binary behind it.
        string scoop = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "scoop\\apps\\godot\\current\\godot.exe");
        if (File.Exists(scoop)) return scoop;
        foreach (string dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';'))
        {
            try
            {
                string candidate = Path.Combine(dir.Trim().Trim('"'), "godot.exe");
                if (dir.Trim().Length > 0 && File.Exists(candidate)) return candidate;
            }
            catch (ArgumentException) { }  // a malformed PATH entry
        }
        return null;
    }

    static bool ViewerRunning()
    {
        using (var client = new TcpClient())
        {
            try
            {
                var attempt = client.BeginConnect("127.0.0.1", ViewerPort, null, null);
                return attempt.AsyncWaitHandle.WaitOne(300) && client.Connected;
            }
            catch (SocketException) { return false; }
        }
    }

    static string Quote(string arg)
    {
        return arg.Length > 0 && arg.IndexOfAny(new[] { ' ', '\t', '"' }) < 0 ? arg : "\"" + arg.Replace("\"", "\\\"") + "\"";
    }

    static void Fail(string message)
    {
        MessageBox.Show(message, "Foundry Godot Viewer", MessageBoxButtons.OK, MessageBoxIcon.Warning);
    }
}
