param([Parameter(Mandatory=$true)][string]$EvidenceDirectory)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class ThumbleDesktopProbe : Form, IMessageFilter {
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    readonly TextBox entry = new TextBox();
    readonly Label status = new Label();
    readonly List<string> events = new List<string>();
    readonly string directory;
    readonly Timer timer = new Timer();
    int saved = -1;
    public ThumbleDesktopProbe(string output) {
        directory = output;
        Text = "Thumble iOS to Windows desktop witness";
        StartPosition = FormStartPosition.Manual;
        Bounds = new Rectangle(30, 30, 900, 650);
        TopMost = true;
        var title = new Label { Text = "Thumble iOS → Windows VM\nNative keyboard and mouse delivery", Bounds = new Rectangle(40, 25, 810, 90), Font = new Font("Segoe UI", 22) };
        entry.Bounds = new Rectangle(50, 130, 780, 60);
        entry.Font = new Font("Segoe UI", 30);
        status.Bounds = new Rectangle(50, 220, 780, 260);
        status.Font = new Font("Segoe UI", 15);
        status.Text = "Waiting for input from the actual iOS app";
        Controls.Add(title); Controls.Add(entry); Controls.Add(status);
        Application.AddMessageFilter(this);
        Shown += (sender, args) => {
            Activate(); SetForegroundWindow(Handle); entry.Focus();
            Cursor.Position = entry.PointToScreen(new Point(120, 25));
            if (GetForegroundWindow() != Handle) throw new Exception("No foreground interactive desktop");
            File.WriteAllText(Path.Combine(directory, "desktop-ready"), "ready");
        };
        timer.Interval = 200;
        timer.Tick += (sender, args) => SaveEvidence();
        timer.Start();
    }
    public bool PreFilterMessage(ref Message message) {
        var control = Control.FromHandle(message.HWnd);
        if (control == null || control.FindForm() != this) return false;
        string kind = null; int code = 0; int value = 0;
        switch (message.Msg) {
            case 0x100: case 0x101:
                kind = "key"; code = message.WParam.ToInt32(); value = message.Msg == 0x100 ? 1 : 0; break;
            case 0x200: kind = "move"; value = 1; break;
            case 0x201: case 0x202:
                kind = "button"; code = 1; value = message.Msg == 0x201 ? 1 : 0; break;
            case 0x20A: case 0x20E: kind = "scroll"; value = 1; break;
        }
        if (kind != null) {
            var p = Cursor.Position;
            events.Add("{\"time\":\"" + DateTime.UtcNow.ToString("O") + "\",\"kind\":\"" + kind + "\",\"code\":" + code + ",\"value\":" + value + ",\"x\":" + p.X + ",\"y\":" + p.Y + "}");
        }
        return false;
    }
    void SaveEvidence() {
        if (saved == events.Count) return;
        saved = events.Count;
        // Only this test window is observed. No global keyboard hooks or text capture.
        string safeText = entry.Text.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\r", "").Replace("\n", "");
        string json = "{\"text\":\"" + safeText + "\",\"events\":[" + string.Join(",", events) + "]}";
        File.WriteAllText(Path.Combine(directory, "desktop-events.json.tmp"), json);
        File.Copy(Path.Combine(directory, "desktop-events.json.tmp"), Path.Combine(directory, "desktop-events.json"), true);
        status.Text = "Text received: " + entry.Text + "\nWindow input messages: " + events.Count + "\n" + (events.Count == 0 ? "" : events[events.Count - 1]);
        using (var bitmap = new Bitmap(Width, Height)) {
            using (var graphics = Graphics.FromImage(bitmap)) graphics.CopyFromScreen(Location, Point.Empty, Size);
            bitmap.Save(Path.Combine(directory, "desktop.png.tmp"), System.Drawing.Imaging.ImageFormat.Png);
            File.Copy(Path.Combine(directory, "desktop.png.tmp"), Path.Combine(directory, "desktop.png"), true);
        }
    }
    public static void Run(string directory) {
        Application.EnableVisualStyles();
        Application.Run(new ThumbleDesktopProbe(directory));
    }
}
'@
[ThumbleDesktopProbe]::Run($EvidenceDirectory)
