using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("Лось SSH")]
[assembly: AssemblyProduct("Лось SSH")]
[assembly: AssemblyDescription("SSH-терминал с вкладками и панелями")]
internal static class Launcher
{
    [STAThread]
    private static int Main(string[] args)
    {
        string root = AppDomain.CurrentDomain.BaseDirectory;
        string engine = Path.Combine(root, "runtime", "wezterm-gui.exe");
        string config = Path.Combine(root, "los-ssh.lua");
        try
        {
            if (args.Length == 1 && args[0] == "--new-screen-id")
            {
                Console.Write(Guid.NewGuid().ToString("N"));
                return 0;
            }
            if (args.Length == 2 && args[0] == "--session-slot")
            {
                Console.Write(ClaimSessionSlot(int.Parse(args[1])));
                return 0;
            }
            if (!File.Exists(engine) || !File.Exists(config))
                throw new FileNotFoundException("Рядом с Лось SSH.exe нужны los-ssh.lua и папка runtime.");
            var launch = new ProcessStartInfo(engine)
            {
                Arguments = "--config-file \"" + config + "\" start --always-new-process",
                WorkingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                UseShellExecute = false
            };
            using (Process.Start(launch)) { }
            return 0;
        }
        catch (Exception error)
        {
            if (args.Length != 0)
            {
                Console.Error.WriteLine(error.Message);
                return 1;
            }
            MessageBox.Show(error.Message, "Лось SSH", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    // Each running GUI owns its slot across config reloads. The start time
    // distinguishes a new Windows process that has inherited a recycled PID.
    private static int ClaimSessionSlot(int pid)
    {
        string dir = Environment.GetEnvironmentVariable("LOS_SSH_SESSION_DIR");
        if (string.IsNullOrEmpty(dir))
            dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LosSSH");
        Directory.CreateDirectory(dir);
        using (var process = Process.GetProcessById(pid))
        using (var mutex = new Mutex(false, @"Local\LosSSH.SessionSlots"))
        {
            try { if (!mutex.WaitOne(5000)) throw new IOException("Session storage is busy."); }
            catch (AbandonedMutexException) { }
            try
            {
                string owner = pid + " " + process.StartTime.ToUniversalTime().Ticks;
                int firstFree = 0;
                for (int slot = 1; ; slot++)
                {
                    string path = Path.Combine(dir, "window-" + slot + ".owner");
                    if (!File.Exists(path))
                    {
                        int chosen = firstFree == 0 ? slot : firstFree;
                        File.WriteAllText(Path.Combine(dir, "window-" + chosen + ".owner"), owner);
                        return chosen;
                    }
                    string previous = File.ReadAllText(path);
                    if (previous == owner) return slot;
                    if (firstFree == 0 && !OwnerIsAlive(previous)) firstFree = slot;
                }
            }
            finally { mutex.ReleaseMutex(); }
        }
    }

    private static bool OwnerIsAlive(string owner)
    {
        string[] parts = owner.Split(' ');
        int pid;
        long ticks;
        if (parts.Length != 2 || !int.TryParse(parts[0], out pid) || !long.TryParse(parts[1], out ticks))
            return false;
        try
        {
            using (var process = Process.GetProcessById(pid))
                return process.StartTime.ToUniversalTime().Ticks == ticks;
        }
        catch (ArgumentException) { return false; }
        catch (InvalidOperationException) { return false; }
        catch (System.ComponentModel.Win32Exception) { return true; }
    }
}
