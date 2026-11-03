// "Foundry Godot Viewer.exe": double-click to start the viewer (play mode), no console window.
// Built by tools\make-launcher.ps1 with the C# compiler that ships with Windows; nothing to install.
//   "Foundry Godot Viewer.exe"                play mode (players)
//   "Foundry Godot Viewer.exe" --dev          dev mode (the GM view); other arguments go to the viewer too
//   "Foundry Godot Viewer.exe" --update-only  update from GitHub, don't start the viewer
// Godot is found in this order: bin\godot.exe next to the exe (portable copy), Scoop's Godot, godot.exe on PATH.
// Before starting, a portable copy updates itself to the latest commit on GitHub (version.txt holds the one it
// has). A folder with .git (the development copy) never updates. Any update problem just starts the current copy.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;

static class FoundryGodotViewer
{
    const int ViewerPort = 8765;  // the viewer's bridge port (bridge_server.gd)
    const string Repo = "Phu-D-Le/foundry-godot-viewer";

    [STAThread]
    static int Main(string[] args)
    {
        string project = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
        if (!File.Exists(Path.Combine(project, "project.godot")))
        {
            Fail("project.godot isn't next to this launcher (" + project + ").\nKeep the exe in the viewer folder.");
            return 1;
        }
        bool updateOnly = args.Contains("--update-only");
        args = args.Where(a => a != "--update-only").ToArray();
        if (updateOnly)
        {
            Update(project);
            return 0;
        }
        if (ViewerRunning())
        {
            Fail("The viewer is already running (port " + ViewerPort + " is in use).\nClose it first, or switch modes in it with Ctrl+`.");
            return 1;
        }
        Update(project);
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

    // Brings the folder up to the latest commit on GitHub, showing a small window while it downloads.
    static void Update(string project)
    {
        string self = Application.ExecutablePath;
        try { File.Delete(self + ".old"); } catch (Exception) { }  // left by the previous update
        if (Directory.Exists(Path.Combine(project, ".git")) || File.Exists(Path.Combine(project, ".git"))) return;
        string latest = LatestCommit();
        string versionFile = Path.Combine(project, "version.txt");
        string current = File.Exists(versionFile) ? File.ReadAllText(versionFile).Trim() : "";
        if (latest == null || latest == current) return;

        Exception error = null;
        var form = new Form
        {
            Text = "Foundry Godot Viewer",
            FormBorderStyle = FormBorderStyle.FixedDialog,
            ControlBox = false,
            StartPosition = FormStartPosition.CenterScreen,
            ClientSize = new System.Drawing.Size(320, 70),
            TopMost = true,
        };
        form.Controls.Add(new Label
        {
            Text = "Updating Foundry Godot Viewer...",
            Dock = DockStyle.Fill,
            TextAlign = System.Drawing.ContentAlignment.MiddleCenter,
        });
        form.Shown += (sender, e) =>
        {
            var worker = new Thread(() =>
            {
                try { Install(project, latest, self); }
                catch (Exception x) { error = x; }
                form.BeginInvoke((Action)form.Close);
            });
            worker.IsBackground = true;
            worker.Start();
        };
        Application.EnableVisualStyles();
        Application.Run(form);
        if (error != null) Fail("Couldn't update the viewer; starting the current version.\n\n" + error.Message);
    }

    // The sha of the newest commit on main, or null when GitHub can't be reached.
    static string LatestCommit()
    {
        string api = Environment.GetEnvironmentVariable("FGV_UPDATE_API") ?? ("https://api.github.com/repos/" + Repo);
        try
        {
            ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;  // .NET 4's default can't reach GitHub
            var request = (HttpWebRequest)WebRequest.Create(api + "/commits/main");
            request.UserAgent = "FoundryGodotViewer";
            request.Accept = "application/vnd.github.sha";
            request.Timeout = 4000;
            request.ReadWriteTimeout = 4000;
            using (var response = request.GetResponse())
            using (var reader = new StreamReader(response.GetResponseStream()))
            {
                string sha = reader.ReadToEnd().Trim();
                return Regex.IsMatch(sha, "^[0-9a-f]{40}$") ? sha : null;
            }
        }
        catch (Exception) { return null; }
    }

    static void Install(string project, string sha, string self)
    {
        string temp = Path.Combine(Path.GetTempPath(), "foundry-godot-viewer-update");
        if (Directory.Exists(temp)) Directory.Delete(temp, true);
        Directory.CreateDirectory(temp);
        try
        {
            string zip = Path.Combine(temp, "update.zip");
            using (var web = new WebClient())
            {
                web.Headers.Add("User-Agent", "FoundryGodotViewer");
                web.DownloadFile("https://github.com/" + Repo + "/archive/" + sha + ".zip", zip);
            }
            string unpacked = Path.Combine(temp, "files");
            ZipFile.ExtractToDirectory(zip, unpacked);
            string root = Directory.GetDirectories(unpacked).Single();  // GitHub puts everything in one folder
            var files = Directory.GetFiles(root, "*", SearchOption.AllDirectories)
                .Select(f => f.Substring(root.Length + 1)).ToList();
            foreach (string file in files)
            {
                string dest = Path.Combine(project, file);
                if (file.Equals("viewer.cfg", StringComparison.OrdinalIgnoreCase) && File.Exists(dest)) continue;  // the player's settings
                Directory.CreateDirectory(Path.GetDirectoryName(dest));
                if (string.Equals(Path.GetFullPath(dest), Path.GetFullPath(self), StringComparison.OrdinalIgnoreCase))
                {
                    // A running exe can't be overwritten, but it can be renamed out of the way.
                    File.Move(self, self + ".old");
                    try { File.Copy(Path.Combine(root, file), dest); }
                    catch (Exception) { File.Move(self + ".old", self); throw; }
                    continue;
                }
                File.Copy(Path.Combine(root, file), dest, true);
            }
            // Files the previous update put here that the new version no longer has.
            string manifest = Path.Combine(project, "files.txt");
            var wanted = new HashSet<string>(files, StringComparer.OrdinalIgnoreCase);
            if (File.Exists(manifest))
            {
                foreach (string old in File.ReadAllLines(manifest).Select(l => l.Trim().Replace('/', '\\')))
                {
                    if (old.Length == 0 || wanted.Contains(old) || old.Contains("..") || Path.IsPathRooted(old)) continue;
                    try { File.Delete(Path.Combine(project, old)); } catch (Exception) { }
                }
            }
            File.WriteAllLines(manifest, files);
            File.WriteAllText(Path.Combine(project, "version.txt"), sha);
        }
        finally
        {
            try { Directory.Delete(temp, true); } catch (Exception) { }
        }
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
