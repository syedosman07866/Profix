// Copyright (c) 2026 Syed Osman (PRO SUPPORT). All rights reserved. Licensed under the MIT License.
// ProFix v1.0.0 - Slow PC Doctor for Windows 10 / 11 (real .exe)
// ------------------------------------------------------------------
// Diagnose why a PC is slow, show a Health Score 0-100, then fix
// only the safe things you choose. Diagnose first, preview everything.
//
// 7 diagnostics: Junk files (ProClean v1.1.0 logic), C: drive free
// space, Startup apps, Memory pressure, CPU load + Uptime, Windows
// Update / Pending reboot (report only), Recycle Bin + DNS.
//
// Health Score - 75/25 Split Architecture (SCORE_SPEC_75_25.md):
//   System Health /75: C: free space 20, RAM pressure (3-sec avg) 15,
//   Startup (non-Microsoft) 12, CPU (5-sec avg) + Uptime 10, Junk 8,
//   Windows Update / Pending Restart 6, Recycle Bin + DNS 4.
//   Hardware Health /25 (read-only WMI/CIM): OS drive type 12
//   (NVMe/SSD 12, Unknown 7, HDD 0), Total RAM 8 (16GB+ 8, 8-15GB 5,
//   <8GB 0), SMART + CPU/Battery 5.
//   Hard caps AFTER the total: SMART failing -> min(score, 39);
//   C: drive under 2 GB free -> min(score, 44).
//   Grade: 85+ Excellent, 65-84 Good, 45-64 Fair, 0-44 Poor.
//   CPU/RAM are sampled over 3-5 sec (never a 1-sec snapshot).
//   Non-admin fallback: drive Unknown 7 pts, SMART Unchecked 5 pts.
//
// Safe fixes only: clean junk, disable selected HKCU Run startup apps
// (reversible - backed up to HKCU\Software\ProFix\DisabledStartup, to
// the log, AND to %LOCALAPPDATA%\ProFix\ProFix_Restore.json; the GUI
// "Undo Last Fix" button restores them), empty Recycle Bin (own
// confirmation) + flush DNS. After every Fix, ProFix re-runs Diagnose
// silently and writes a Before vs After report (ProFix-Report-*.txt).
// No automatic fix for C: full, CPU/RAM high, pending reboot or long
// uptime - a plain-English recommendation is shown instead. Never kills
// processes, never changes power plans, never touches the registry
// except the HKCU Run disable above, never deletes all Prefetch,
// never auto-restarts the PC.
//
// Built from the same design as ProFix.ps1 v1.0.0, rebuilt as a real
// Windows program so there is no PowerShell, no execution policy and
// no paste-into-console step. Double-click and it runs.
// Console diagnose: ProFix.exe /DIAGNOSE   (deletes nothing)
// Silent safe fix:  ProFix.exe /AUTO        (Junk + DNS only)
//
// Author  : PRO SUPPORT (Syed Osman)
// Version : 1.0.0 - 19 Nov 2026
// License : MIT - free to use, share and modify
// Needs   : Windows 10 / 11 (.NET 8 runtime is bundled inside the exe,
//           no install needed on the PC)

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Management;
using System.Net;
using System.Threading;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.ServiceProcess;
using System.Text;
using System.Text.Json;
using System.Windows.Forms;
using Microsoft.Win32;

namespace ProFix
{
    static class Program
    {
        public const string AppVersion = "1.0.0";

        [STAThread]
        static void Main(string[] args)
        {
            if (args != null)
            {
                foreach (string a in args)
                {
                    if (a.Equals("/DIAGNOSE", StringComparison.OrdinalIgnoreCase)
                        || a.Equals("-DiagnoseOnly", StringComparison.OrdinalIgnoreCase)
                        || a.Equals("--diagnose", StringComparison.OrdinalIgnoreCase))
                    {
                        RunDiagnoseOnly();
                        return;
                    }
                    if (a.Equals("/AUTO", StringComparison.OrdinalIgnoreCase)
                        || a.Equals("-AutoFix", StringComparison.OrdinalIgnoreCase)
                        || a.Equals("--autofix", StringComparison.OrdinalIgnoreCase))
                    {
                        RunAutoFix();
                        return;
                    }
                }
            }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm());
        }

        static void RunDiagnoseOnly()
        {
            Console.WriteLine("ProFix v" + AppVersion + " - console diagnose (nothing will be changed)");
            Console.WriteLine("Admin: " + Util.IsAdmin());
            var diag = Engine.Diagnose();
            Console.WriteLine();
            Console.WriteLine(string.Format("Health Score: {0} - {1}", diag.Score, diag.Grade));
            Console.WriteLine(string.Format("System Health: {0} / 75  |  Hardware Health: {1} / 25",
                diag.SoftwareScore, diag.HardwareScore));
            if (!string.IsNullOrEmpty(diag.CapReason)) Console.WriteLine("CAP: " + diag.CapReason);
            Console.WriteLine(string.Format("1-Click Fix se +{0} points turant badhenge.", diag.InstantFixable));
            Console.WriteLine(diag.Verdict);
            foreach (var d in Engine.Diagnostics)
            {
                var it = diag.Items[d.Id];
                Console.WriteLine(string.Format("- {0}: {1} | {2} | Fix: {3}",
                    it.Name, it.Status, it.Detail, it.Fix));
            }
            Console.WriteLine("Log: " + Logger.LogPath);
        }

        static void RunAutoFix()
        {
            Console.WriteLine("ProFix v" + AppVersion + " - AutoFix mode (silent, Junk + DNS only)");
            bool isAdmin = Util.IsAdmin();
            Console.WriteLine("Admin: " + isAdmin);
            Logger.Write("ProFix v" + AppVersion + " - AutoFix started.");
            var diag = Engine.Diagnose();
            int scoreBefore = diag.Score;
            string gradeBefore = diag.Grade;
            int softwareBefore = diag.SoftwareScore;
            int hardwareBefore = diag.HardwareScore;
            Console.WriteLine(string.Format("Health Score: {0} - {1}", diag.Score, diag.Grade));
            long deleted, skipped, freed; int disabled;
            // Junk only; Recycle Bin is NOT emptied silently and no startup
            // app is disabled silently. DNS is flushed separately below.
            Engine.Fix(new List<string> { "Junk" }, isAdmin, false, null,
                out deleted, out skipped, out freed, out disabled);
            Engine.LastFixDnsFlushed = Util.FlushDns();
            RestoreStore.WriteRestoreJson(scoreBefore, gradeBefore, deleted, freed, 0, softwareBefore, hardwareBefore);
            var after = Engine.Diagnose();
            string reportPath = Report.WriteBeforeAfterReport(scoreBefore, gradeBefore, after,
                deleted, freed, new List<string>(), Engine.LastFixRecycleEmptied, 0,
                Engine.LastFixDnsFlushed, Engine.LastFixRestorePointCreated, softwareBefore, hardwareBefore);
            Console.WriteLine(string.Format("Fix done: {0} files deleted ({1} freed), {2} skipped.",
                deleted, Util.FormatSize(freed), skipped));
            Console.WriteLine(string.Format("Health Score: {0} -> {1}  (System {2}/75 + Hardware {3}/25 -> System {4}/75 + Hardware {5}/25)",
                scoreBefore, after.Score, softwareBefore, hardwareBefore, after.SoftwareScore, after.HardwareScore));
            Console.WriteLine("Report: " + reportPath);
            Console.WriteLine("Log: " + Logger.LogPath);
        }
    }

    class Diagnostic
    {
        public string Id;
        public string Name;
        public string Desc;
        public bool DefaultFix;
    }

    class DiagItem
    {
        public string Name;
        public string Status = "Good"; // Good | Warning | Bad
        public string Detail = "";
        public string Fix = "";
        public int Delta; // Points - MaxPoints (<= 0)
        public int Points;
        public int MaxPoints;
    }

    class Diagnosis
    {
        public int Score;
        public string Grade;
        public string Verdict;
        public int SoftwareScore; // out of 75
        public int HardwareScore; // out of 25
        public string CapReason; // null when no hard cap applied
        public int InstantFixable; // points 1-Click Fix can gain at once
        public Dictionary<string, int> Breakdown = new Dictionary<string, int>();
        public Dictionary<string, DiagItem> Items = new Dictionary<string, DiagItem>();
        public long RecycleCount;
        public long RecycleSize;
    }

    class HardwareInfo
    {
        public string DriveType = "Unknown";
        public int DrivePoints = 7;
        public double TotalRamGB;
        public int RamPoints;
        public bool SmartOk = true;
        public bool SmartChecked;
        public int CpuThreads;
        public double? BatteryPct; // null = desktop / no battery = OK
        public int HealthPoints = 5;
        public string Note = "";
    }

    class ScoreResult
    {
        public int Total;
        public string Grade;
        public string Verdict;
        public int Software;
        public int Hardware;
        public string CapReason;
        public int InstantFixable;
        public Dictionary<string, int> Breakdown = new Dictionary<string, int>();
    }

    class StartupApp
    {
        public string Name;
        public string Command;
        public string Location; // HKCU Run | HKLM Run | HKLM Run (32-bit) | Startup Folder (user/all users) | WMI location
        public bool DisableSelected; // chosen in the Startup detail dialog; HKCU Run only
    }

    // One reversible change: a disabled HKCU Run startup app, with its
    // full original command value so Undo can put it back exactly.
    class RestoreEntry
    {
        public string Name;
        public string OriginalLocation; // always "HKCU Run" in v1.0
        public string Value;
        public string BackupRegistryPath;
        public bool Restorable = true;
    }

    static class Native
    {
        [DllImport("shell32.dll", CharSet = CharSet.Auto)]
        public static extern uint SHEmptyRecycleBin(IntPtr hwnd, string pszRootPath, uint dwFlags);

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
        public struct SHQUERYRBINFO
        {
            public uint cbSize;
            public long i64Size;
            public long i64NumItems;
        }

        [DllImport("shell32.dll", CharSet = CharSet.Auto)]
        public static extern int SHQueryRecycleBin(string pszRootPath, ref SHQUERYRBINFO pInfo);

        public const uint SHERB_NOCONFIRMATION = 0x00000001;
        public const uint SHERB_NOPROGRESSUI = 0x00000002;
        public const uint SHERB_NOSOUND = 0x00000004;
    }

    static class Util
    {
        public static bool IsAdmin()
        {
            try
            {
                var id = WindowsIdentity.GetCurrent();
                var p = new WindowsPrincipal(id);
                return p.IsInRole(WindowsBuiltInRole.Administrator);
            }
            catch { return false; }
        }

        public static string FormatSize(long bytes)
        {
            if (bytes >= 1024L * 1024 * 1024) return string.Format("{0:N2} GB", bytes / (1024.0 * 1024 * 1024));
            if (bytes >= 1024L * 1024) return string.Format("{0:N2} MB", bytes / (1024.0 * 1024));
            if (bytes >= 1024L) return string.Format("{0:N2} KB", bytes / 1024.0);
            return bytes + " bytes";
        }

        public static string TempPath { get { return Path.GetTempPath(); } }
        public static string WinDir { get { return Environment.GetEnvironmentVariable("SystemRoot") ?? @"C:\Windows"; } }
        public static string LocalAppData { get { return Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData); } }
        public static string RoamingAppData { get { return Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData); } }
        public static string ProgramData { get { return Environment.GetEnvironmentVariable("ProgramData") ?? @"C:\ProgramData"; } }
        public static string Desktop { get { return Environment.GetFolderPath(Environment.SpecialFolder.Desktop); } }

        // ProClean v1.1.0 browser-cache logic, unchanged.
        public static List<string> GetBrowserCachePaths()
        {
            var paths = new List<string>();
            foreach (string baseDir in new[]
            {
                Path.Combine(LocalAppData, @"Google\Chrome\User Data"),
                Path.Combine(LocalAppData, @"Microsoft\Edge\User Data")
            })
            {
                if (!Directory.Exists(baseDir)) continue;
                var profiles = new List<string> { "Default", "Guest Profile" };
                try
                {
                    foreach (string d in Directory.GetDirectories(baseDir, "Profile *"))
                        profiles.Add(Path.GetFileName(d));
                }
                catch { }
                foreach (string profile in profiles)
                {
                    foreach (string sub in new[] { "Cache", @"Cache\Cache_Data", "Code Cache", "GPUCache" })
                        paths.Add(Path.Combine(Path.Combine(baseDir, profile), sub));
                }
            }
            string opera = Path.Combine(RoamingAppData, @"Opera Software\Opera Stable\Cache");
            if (Directory.Exists(opera)) paths.Add(opera);
            string ffProfiles = Path.Combine(RoamingAppData, @"Mozilla\Firefox\Profiles");
            if (Directory.Exists(ffProfiles))
            {
                foreach (string dir in Directory.GetDirectories(ffProfiles))
                    paths.Add(Path.Combine(dir, "cache2"));
            }
            return paths;
        }

        public static bool IsBrowserRunning()
        {
            foreach (string name in new[] { "chrome", "msedge", "firefox", "opera" })
            {
                try { if (Process.GetProcessesByName(name).Length > 0) return true; }
                catch { }
            }
            return false;
        }

        // ProClean v1.1.0 collection logic, unchanged: skip reparse points
        // and files newer than MinAgeHours. Never throws.
        public static void CollectFiles(string[] roots, int minAgeHours, List<FileInfo> outList)
        {
            DateTime cutoff = DateTime.Now.AddHours(-minAgeHours);
            foreach (string root in roots)
            {
                if (string.IsNullOrEmpty(root) || !Directory.Exists(root)) continue;
                var stack = new Stack<string>();
                stack.Push(root);
                while (stack.Count > 0)
                {
                    string dir = stack.Pop();
                    string[] subdirs = null;
                    string[] files = null;
                    try { subdirs = Directory.GetDirectories(dir); } catch { continue; }
                    try { files = Directory.GetFiles(dir); } catch { }
                    if (files != null)
                    {
                        foreach (string f in files)
                        {
                            try
                            {
                                var fi = new FileInfo(f);
                                if ((fi.Attributes & FileAttributes.ReparsePoint) != 0) continue;
                                if (minAgeHours > 0 && fi.LastWriteTime >= cutoff) continue;
                                outList.Add(fi);
                            }
                            catch { }
                        }
                    }
                    if (subdirs != null)
                    {
                        foreach (string d in subdirs) stack.Push(d);
                    }
                }
            }
        }

        public static bool GetRecycleBinInfo(out long count, out long size)
        {
            count = 0; size = 0;
            try
            {
                var info = new Native.SHQUERYRBINFO();
                info.cbSize = (uint)Marshal.SizeOf(typeof(Native.SHQUERYRBINFO));
                int hr = Native.SHQueryRecycleBin(null, ref info);
                if (hr == 0)
                {
                    count = info.i64NumItems;
                    size = info.i64Size;
                    return true;
                }
            }
            catch { }
            return false;
        }

        public static bool CreateRestorePoint()
        {
            try
            {
                var scope = new ManagementScope(@"\\.\root\default");
                scope.Connect();
                var cls = new ManagementClass(scope, new ManagementPath("SystemRestore"), null);
                var inParams = cls.GetMethodParameters("CreateRestorePoint");
                inParams["Description"] = "ProFix before fixing";
                inParams["RestorePointType"] = 12; // MODIFY_SETTINGS
                inParams["EventType"] = 100; // BEGIN_SYSTEM_CHANGE
                cls.InvokeMethod("CreateRestorePoint", inParams, null);
                return true;
            }
            catch (Exception ex)
            {
                Logger.Write("Restore Point could not be created (Windows allows one per day, or restore is off): " + ex.Message);
                return false;
            }
        }

        public static bool FlushDns()
        {
            try
            {
                var psi = new ProcessStartInfo("ipconfig", "/flushdns");
                psi.UseShellExecute = false;
                psi.RedirectStandardOutput = true;
                psi.CreateNoWindow = true;
                using (var p = Process.Start(psi))
                {
                    string output = p.StandardOutput.ReadToEnd();
                    p.WaitForExit();
                    Logger.Write("DNS cache flushed. " + output.Trim().Replace("\r", " ").Replace("\n", " "));
                }
                return true;
            }
            catch (Exception ex)
            {
                Logger.Write("DNS flush failed: " + ex.Message);
                return false;
            }
        }
    }

    static class Logger
    {
        public static string LogPath;
        public static TextBox LogBox;

        static Logger()
        {
            LogPath = Path.Combine(Util.Desktop,
                "ProFix-Log-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".txt");
        }

        public static void Write(string message)
        {
            string line = "[" + DateTime.Now.ToString("HH:mm:ss") + "] " + message;
            try { File.AppendAllText(LogPath, line + Environment.NewLine); } catch { }
            if (LogBox != null)
            {
                LogBox.AppendText(line + Environment.NewLine);
                LogBox.SelectionStart = LogBox.Text.Length;
                LogBox.ScrollToCaret();
            }
        }
    }


    // ------------------------------------------------------------------
    // ProFix_Restore.json + Undo Last Fix (Safe by Design).
    //   File: %LOCALAPPDATA%\ProFix\ProFix_Restore.json
    //   In v1.0 the ONLY restorable changes are HKCU Run startup
    //   disables. Junk deleted / Recycle Bin emptied / DNS flushed are
    //   recorded as NOT restorable - the JSON says so, and Undo says so.
    //   Undo writes back ONLY to HKCU Run and deletes ONLY ProFix's own
    //   backup values under HKCU\Software\ProFix\DisabledStartup.
    //   Nothing else in the registry is ever written by Undo.
    // ------------------------------------------------------------------
    static class RestoreStore
    {
        public static string RestoreDir
        {
            get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ProFix"); }
        }

        public static string RestorePath
        {
            get { return Path.Combine(RestoreDir, "ProFix_Restore.json"); }
        }

        static string JsonEscape(string value)
        {
            if (value == null) return "";
            var sb = new StringBuilder();
            foreach (char c in value)
            {
                switch (c)
                {
                    case '"': sb.Append("\\\""); break;
                    case '\\': sb.Append("\\\\"); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': sb.Append("\\r"); break;
                    case '\t': sb.Append("\\t"); break;
                    default:
                        if (c < 0x20) sb.Append(string.Format("\\u{0:x4}", (int)c));
                        else sb.Append(c);
                        break;
                }
            }
            return sb.ToString();
        }

        // Called by the GUI / AutoFix caller AFTER the fix finishes, so
        // the JSON reflects the completed fix (incl. the DNS flush).
        public static string WriteRestoreJson(int scoreBefore, string gradeBefore,
            long junkDeleted, long junkFreedBytes, long recycleItems,
            int softwareBefore = 0, int hardwareBefore = 0)
        {
            try
            {
                Directory.CreateDirectory(RestoreDir);
                var sb = new StringBuilder();
                sb.AppendLine("{");
                sb.AppendLine("  \"App\": \"ProFix\",");
                sb.AppendLine("  \"Version\": \"" + JsonEscape(Program.AppVersion) + "\",");
                sb.AppendLine("  \"Timestamp\": \"" + DateTime.Now.ToString("yyyy-MM-ddTHH:mm:ss") + "\",");
                sb.AppendLine("  \"HealthScoreBefore\": " + scoreBefore + ",");
                sb.AppendLine("  \"HealthGradeBefore\": \"" + JsonEscape(gradeBefore) + "\",");
                sb.AppendLine("  \"SoftwareScoreBefore\": " + softwareBefore + ",");
                sb.AppendLine("  \"HardwareScoreBefore\": " + hardwareBefore + ",");
                sb.AppendLine("  \"RestorePointCreated\": " + (Engine.LastFixRestorePointCreated ? "true" : "false") + ",");
                sb.AppendLine("  \"JunkDeletedCount\": " + junkDeleted + ",");
                sb.AppendLine("  \"JunkFreedBytes\": " + junkFreedBytes + ",");
                sb.AppendLine("  \"JunkRestorable\": false,");
                sb.AppendLine("  \"RecycleBinEmptied\": " + (Engine.LastFixRecycleEmptied ? "true" : "false") + ",");
                sb.AppendLine("  \"RecycleBinItems\": " + recycleItems + ",");
                sb.AppendLine("  \"DnsFlushed\": " + (Engine.LastFixDnsFlushed ? "true" : "false") + ",");
                sb.AppendLine("  \"StartupDisabled\": [");
                for (int i = 0; i < Engine.LastFixDisabledEntries.Count; i++)
                {
                    var e = Engine.LastFixDisabledEntries[i];
                    sb.AppendLine("    {");
                    sb.AppendLine("      \"Name\": \"" + JsonEscape(e.Name) + "\",");
                    sb.AppendLine("      \"OriginalLocation\": \"" + JsonEscape(e.OriginalLocation) + "\",");
                    sb.AppendLine("      \"Value\": \"" + JsonEscape(e.Value) + "\",");
                    sb.AppendLine("      \"BackupRegistryPath\": \"" + JsonEscape(e.BackupRegistryPath) + "\",");
                    sb.AppendLine("      \"Restorable\": " + (e.Restorable ? "true" : "false"));
                    sb.AppendLine("    }" + (i < Engine.LastFixDisabledEntries.Count - 1 ? "," : ""));
                }
                sb.AppendLine("  ],");
                sb.AppendLine("  \"NonRestorableNote\": \"Deleted junk files cannot be restored - use the System Restore Point created before fixing if needed.\"");
                sb.AppendLine("}");
                File.WriteAllText(RestorePath, sb.ToString(), new UTF8Encoding(false));
                Logger.Write("Restore backup written: " + RestorePath);
                return RestorePath;
            }
            catch (Exception ex)
            {
                Logger.Write("Restore backup could not be written: " + ex.Message);
                return null;
            }
        }

        // Returns the restorable startup entries, or an empty list when
        // the file is missing, corrupt, or has no restorable entries.
        // Never throws.
        public static List<RestoreEntry> GetRestorableEntries()
        {
            var entries = new List<RestoreEntry>();
            try
            {
                if (!File.Exists(RestorePath)) return entries;
                string json = File.ReadAllText(RestorePath);
                using (var doc = JsonDocument.Parse(json))
                {
                    JsonElement list;
                    if (!doc.RootElement.TryGetProperty("StartupDisabled", out list)) return entries;
                    foreach (var el in list.EnumerateArray())
                    {
                        bool restorable = true;
                        JsonElement r;
                        if (el.TryGetProperty("Restorable", out r) && r.ValueKind == JsonValueKind.False)
                            restorable = false;
                        if (!restorable) continue;
                        var entry = new RestoreEntry();
                        JsonElement v;
                        entry.Name = el.TryGetProperty("Name", out v) ? (v.GetString() ?? "") : "";
                        entry.OriginalLocation = el.TryGetProperty("OriginalLocation", out v) ? (v.GetString() ?? "HKCU Run") : "HKCU Run";
                        entry.Value = el.TryGetProperty("Value", out v) ? (v.GetString() ?? "") : "";
                        entry.BackupRegistryPath = el.TryGetProperty("BackupRegistryPath", out v) ? (v.GetString() ?? "") : "";
                        entry.Restorable = true;
                        if (string.IsNullOrEmpty(entry.Name)) continue;
                        entries.Add(entry);
                    }
                }
            }
            catch (Exception ex)
            {
                Logger.Write("Restore backup could not be read (missing or corrupt): " + ex.Message);
            }
            return entries;
        }

        public static bool HasRestorableEntries()
        {
            try { return GetRestorableEntries().Count > 0; }
            catch { return false; }
        }

        // Restores every startup app in the JSON, then renames the JSON
        // to ProFix_Restore-UNDONE-<timestamp>.json so Undo cannot run
        // twice on the same backup. Returns false only when there was
        // nothing restorable to do.
        public static bool UndoLastFix(out int restored, out int failed,
            out List<string> names, out string undonePath)
        {
            restored = 0; failed = 0; names = new List<string>(); undonePath = null;
            var entries = GetRestorableEntries();
            if (entries.Count == 0) return false;
            const string runSub = @"Software\Microsoft\Windows\CurrentVersion\Run";
            const string backupSub = @"Software\ProFix\DisabledStartup";
            foreach (var e in entries)
            {
                try
                {
                    using (var runKey = Registry.CurrentUser.CreateSubKey(runSub))
                    {
                        runKey.SetValue(e.Name, e.Value, RegistryValueKind.String);
                    }
                    try
                    {
                        using (var backupKey = Registry.CurrentUser.OpenSubKey(backupSub, true))
                        {
                            if (backupKey != null) backupKey.DeleteValue(e.Name, false);
                        }
                    }
                    catch { }
                    restored++;
                    names.Add(e.Name);
                    Logger.Write("Undo: restored startup app [" + e.Name + "]");
                }
                catch (Exception ex)
                {
                    failed++;
                    Logger.Write("Undo failed: " + e.Name + " - " + ex.Message);
                }
            }
            try
            {
                using (var backupKey = Registry.CurrentUser.OpenSubKey(backupSub, false))
                {
                    if (backupKey != null && backupKey.GetValueNames().Length == 0)
                        Registry.CurrentUser.DeleteSubKey(backupSub, false);
                }
            }
            catch { }
            try
            {
                undonePath = Path.Combine(RestoreDir,
                    "ProFix_Restore-UNDONE-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".json");
                File.Move(RestorePath, undonePath);
                Logger.Write("Restore backup moved to: " + undonePath);
            }
            catch (Exception ex)
            {
                Logger.Write("Restore backup could not be renamed after undo: " + ex.Message);
            }
            return true;
        }
    }

    // Before vs After Health Report - plain text in v1.0 (no HTML yet).
    static class Report
    {
        public static string WriteBeforeAfterReport(int scoreBefore, string gradeBefore,
            Diagnosis after, long deleted, long freed, List<string> disabledNames,
            bool recycleEmptied, long recycleItems, bool dnsFlushed, bool restorePointCreated,
            int softwareBefore = 0, int hardwareBefore = 0)
        {
            string reportPath = Path.Combine(Util.Desktop,
                "ProFix-Report-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".txt");
            try
            {
                var lines = new List<string>();
                lines.Add("ProFix v" + Program.AppVersion + " - Before vs After Health Report");
                lines.Add("Date: " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"));
                lines.Add("");
                lines.Add(string.Format("Health Score: {0} ({1}) -> {2} ({3})",
                    scoreBefore, gradeBefore, after.Score, after.Grade));
                lines.Add(string.Format("System Health: {0}/75 + Hardware Health: {1}/25 = {2}  ->  System Health: {3}/75 + Hardware Health: {4}/25 = {5}",
                    softwareBefore, hardwareBefore, scoreBefore, after.SoftwareScore, after.HardwareScore, after.Score));
                if (!string.IsNullOrEmpty(after.CapReason)) lines.Add("CAP APPLIED: " + after.CapReason);
                lines.Add(string.Format("Freed: {0} ({1} files deleted)", Util.FormatSize(freed), deleted));
                lines.Add("Startup Apps Disabled: " + disabledNames.Count);
                foreach (string n in disabledNames) lines.Add("  - " + n);
                if (recycleEmptied) lines.Add(string.Format("Recycle Bin: Emptied ({0} items)", recycleItems));
                else if (recycleItems == 0) lines.Add("Recycle Bin: Already empty");
                else lines.Add("Recycle Bin: Kept (not confirmed)");
                lines.Add("DNS: " + (dnsFlushed ? "Flushed" : "Not flushed"));
                lines.Add("Restore Point: " + (restorePointCreated ? "Created" : "Not created"));
                lines.Add("");
                lines.Add("Recommendations still open:");
                bool anyOpen = false;
                foreach (var d in Engine.Diagnostics)
                {
                    var it = after.Items[d.Id];
                    if (it.Status != "Good")
                    {
                        anyOpen = true;
                        lines.Add(string.Format("- {0} ({1}): {2} | {3}", it.Name, it.Status, it.Detail, it.Fix));
                    }
                }
                if (!anyOpen) lines.Add("  None - all checks Good.");
                lines.Add("");
                lines.Add("Note: Deleted junk files cannot be restored. Startup apps disabled by this fix can be restored with the Undo Last Fix button (ProFix_Restore.json).");
                File.WriteAllLines(reportPath, lines.ToArray(), new UTF8Encoding(false));
                Logger.Write("Before/After report written: " + reportPath);
                return reportPath;
            }
            catch (Exception ex)
            {
                Logger.Write("Before/After report could not be written: " + ex.Message);
                return null;
            }
        }
    }

    // ------------------------------------------------------------------
    // Diagnose + fix engine. Diagnostics are DATA, not hardcoded logic.
    // ------------------------------------------------------------------
    static class Engine
    {
        public static readonly List<Diagnostic> Diagnostics = new List<Diagnostic>
        {
            new Diagnostic { Id = "Junk", Name = "Junk Files", Desc = "Temp + browser caches + old logs / shader / error reports", DefaultFix = true },
            new Diagnostic { Id = "DriveC", Name = "C: Drive Free Space", Desc = "How full the system drive is", DefaultFix = false },
            new Diagnostic { Id = "Startup", Name = "Startup Apps", Desc = "Apps that launch at Windows startup", DefaultFix = false },
            new Diagnostic { Id = "Memory", Name = "Memory (RAM) Pressure", Desc = "Total RAM, free RAM, % used", DefaultFix = false },
            new Diagnostic { Id = "CpuUptime", Name = "CPU Load + Uptime", Desc = "CPU load and days since last restart", DefaultFix = false },
            new Diagnostic { Id = "UpdateReboot", Name = "Windows Update / Reboot", Desc = "Pending reboot + Windows Update service status", DefaultFix = false },
            new Diagnostic { Id = "RecycleDns", Name = "Recycle Bin + DNS", Desc = "Recycle Bin size + DNS cache", DefaultFix = false },
            new Diagnostic { Id = "HwDrive", Name = "Hardware: OS Drive", Desc = "HDD vs SSD/NVMe boot drive (read-only)", DefaultFix = false },
            new Diagnostic { Id = "HwRam", Name = "Hardware: Total RAM", Desc = "Total physical RAM installed (read-only)", DefaultFix = false },
            new Diagnostic { Id = "HwHealth", Name = "Hardware: Disk + CPU", Desc = "SMART disk health + CPU threads + battery (read-only)", DefaultFix = false },
        };

        // Set by the GUI before Diagnose so the sampling loop can show
        // progress; null in console mode.
        public static Action<string, int> StatusUpdate;

        public static Diagnosis Current;
        public static List<FileInfo> JunkFiles = new List<FileInfo>();
        public static List<StartupApp> StartupApps = new List<StartupApp>();

        // Outcome of the most recent Fix, read by RestoreStore + Report.
        public static bool LastFixRestorePointCreated;
        public static bool LastFixRecycleEmptied;
        public static bool LastFixDnsFlushed;
        public static List<RestoreEntry> LastFixDisabledEntries = new List<RestoreEntry>();

        static string Grade(int score)
        {
            if (score >= 85) return "Excellent";
            if (score >= 65) return "Good";
            if (score >= 45) return "Fair";
            return "Poor";
        }

        static string Verdict(int score)
        {
            if (score >= 85) return "PC healthy hai - koi major bottleneck nahi.";
            if (score >= 65) return "Smooth chal raha hai, minor cleanup se aur tez hoga.";
            if (score >= 45) return "Noticeable slowdown hai - 1-Click Fix recommend hai.";
            return "Heavy bottleneck ya critical issue - immediate action chahiye.";
        }

        internal static Color ScoreColor(int score)
        {
            if (score >= 85) return Color.DarkGreen;
            if (score >= 65) return Color.Teal;
            if (score >= 45) return Color.DarkOrange;
            return Color.DarkRed;
        }

        // --- 75/25 scoring helpers (exact port of calculate_health_score) ---
        static void SampleCpuRam(out int cpuPct, out double ramUsedPct, out long totalMem, out long freeMem)
        {
            // NO 1-sec snapshot: ProFix itself spikes CPU on launch. Wait
            // 1 sec, then sample 4 times, 1 sec apart, and average.
            Logger.Write("Measuring CPU/RAM (3-5 sec average)...");
            Thread.Sleep(1000);
            var cpuSamples = new List<double>();
            var ramSamples = new List<double>();
            var freeSamples = new List<long>();
            totalMem = 0;
            for (int i = 0; i < 4; i++)
            {
                try
                {
                    using (var searcher = new ManagementObjectSearcher("SELECT LoadPercentage FROM Win32_Processor"))
                    {
                        double sum = 0; int n = 0;
                        foreach (ManagementObject mo in searcher.Get())
                        {
                            if (mo["LoadPercentage"] != null) { sum += Convert.ToDouble(mo["LoadPercentage"]); n++; }
                        }
                        if (n > 0) cpuSamples.Add(sum / n);
                    }
                }
                catch { }
                try
                {
                    using (var searcher = new ManagementObjectSearcher("SELECT TotalVisibleMemorySize, FreePhysicalMemory FROM Win32_OperatingSystem"))
                    {
                        foreach (ManagementObject mo in searcher.Get())
                        {
                            long totalKB = Convert.ToInt64(mo["TotalVisibleMemorySize"]);
                            long freeKB = Convert.ToInt64(mo["FreePhysicalMemory"]);
                            if (totalKB > 0)
                            {
                                ramSamples.Add((double)(totalKB - freeKB) / totalKB * 100);
                                freeSamples.Add(freeKB * 1024);
                                totalMem = totalKB * 1024;
                            }
                        }
                    }
                }
                catch { }
                try { if (StatusUpdate != null) StatusUpdate("Measuring CPU/RAM (3-5 sec average)...", 10 + (i + 1) * 10); } catch { }
                if (i < 3) Thread.Sleep(1000);
            }
            cpuPct = 0;
            if (cpuSamples.Count > 0)
            {
                double s = 0; foreach (double v in cpuSamples) s += v;
                cpuPct = (int)Math.Round(s / cpuSamples.Count);
            }
            ramUsedPct = 0;
            if (ramSamples.Count > 0)
            {
                double s = 0; foreach (double v in ramSamples) s += v;
                ramUsedPct = Math.Round(s / ramSamples.Count, 1);
            }
            freeMem = 0;
            if (freeSamples.Count > 0)
            {
                long s = 0; foreach (long v in freeSamples) s += v;
                freeMem = s / freeSamples.Count;
            }
        }

        static HardwareInfo GetHardwareInfo()
        {
            // All read-only WMI/CIM. Never throws. Non-admin fallback:
            // drive Unknown (7 pts) and SMART Unchecked (5 pts).
            var hw = new HardwareInfo();
            try
            {
                long sum = 0;
                using (var searcher = new ManagementObjectSearcher("SELECT Capacity FROM Win32_PhysicalMemory"))
                {
                    foreach (ManagementObject mo in searcher.Get())
                        sum += Convert.ToInt64(mo["Capacity"]);
                }
                if (sum > 0) hw.TotalRamGB = Math.Round(sum / (1024.0 * 1024 * 1024), 1);
            }
            catch
            {
                try
                {
                    using (var searcher = new ManagementObjectSearcher("SELECT TotalPhysicalMemory FROM Win32_ComputerSystem"))
                    {
                        foreach (ManagementObject mo in searcher.Get())
                            hw.TotalRamGB = Math.Round(Convert.ToInt64(mo["TotalPhysicalMemory"]) / (1024.0 * 1024 * 1024), 1);
                    }
                }
                catch { }
            }
            try
            {
                int t = 0;
                using (var searcher = new ManagementObjectSearcher("SELECT NumberOfLogicalProcessors FROM Win32_Processor"))
                {
                    foreach (ManagementObject mo in searcher.Get())
                        t += Convert.ToInt32(mo["NumberOfLogicalProcessors"]);
                }
                if (t > 0) hw.CpuThreads = t;
            }
            catch { }
            if (hw.CpuThreads <= 0) hw.CpuThreads = Environment.ProcessorCount;
            // OS drive type: map C: -> disk index -> DiskDrive model ->
            // MSFT_PhysicalDisk FriendlyName (MediaType 4/5 = SSD, 3 = HDD,
            // BusType 17 = NVMe). Single-disk fallback if mapping fails.
            string driveType = null;
            try
            {
                int diskIndex = -1;
                using (var searcher = new ManagementObjectSearcher("SELECT Antecedent FROM Win32_LogicalDiskToPartition WHERE Dependent = 'Win32_LogicalDisk.DeviceID=\"C:\"'"))
                {
                    foreach (ManagementObject mo in searcher.Get())
                    {
                        string ant = Convert.ToString(mo["Antecedent"]) ?? "";
                        var m = System.Text.RegularExpressions.Regex.Match(ant, @"Disk #(\d+)");
                        if (m.Success) diskIndex = int.Parse(m.Groups[1].Value);
                    }
                }
                string model = null;
                if (diskIndex >= 0)
                {
                    using (var searcher = new ManagementObjectSearcher("SELECT Index, Model FROM Win32_DiskDrive"))
                    {
                        foreach (ManagementObject mo in searcher.Get())
                        {
                            if (Convert.ToInt32(mo["Index"]) == diskIndex)
                                model = Convert.ToString(mo["Model"]);
                        }
                    }
                }
                var scope = new ManagementScope(@"\\.\root\Microsoft\Windows\Storage");
                scope.Connect();
                using (var searcher = new ManagementObjectSearcher(scope, new ObjectQuery("SELECT FriendlyName, MediaType, BusType FROM MSFT_PhysicalDisk")))
                {
                    var disks = new List<ManagementObject>();
                    foreach (ManagementObject mo in searcher.Get()) disks.Add(mo);
                    ManagementObject chosen = null;
                    if (!string.IsNullOrEmpty(model))
                    {
                        foreach (var d in disks)
                            if (string.Equals(Convert.ToString(d["FriendlyName"])?.Trim(), model.Trim(), StringComparison.OrdinalIgnoreCase))
                                chosen = d;
                    }
                    if (chosen == null && disks.Count == 1) chosen = disks[0];
                    if (chosen != null)
                    {
                        int mt = Convert.ToInt32(chosen["MediaType"]);
                        int bt = Convert.ToInt32(chosen["BusType"]);
                        if (bt == 17 || mt == 4 || mt == 5) driveType = "SSD";
                        else if (mt == 3) driveType = "HDD";
                    }
                }
            }
            catch { }
            if (!string.IsNullOrEmpty(driveType)) hw.DriveType = driveType;
            // SMART: root\wmi MSStorageDriver_FailurePredictStatus.
            // A failed query means Unchecked, never Failing.
            try
            {
                var scope = new ManagementScope(@"\\.\root\wmi");
                scope.Connect();
                using (var searcher = new ManagementObjectSearcher(scope, new ObjectQuery("SELECT PredictFailure FROM MSStorageDriver_FailurePredictStatus")))
                {
                    bool any = false;
                    foreach (ManagementObject mo in searcher.Get())
                    {
                        any = true;
                        if (mo["PredictFailure"] != null && Convert.ToBoolean(mo["PredictFailure"]))
                            hw.SmartOk = false;
                    }
                    if (any) hw.SmartChecked = true;
                }
            }
            catch { hw.SmartChecked = false; }
            // Battery health (laptops): worst battery; none = OK.
            try
            {
                using (var searcher = new ManagementObjectSearcher("SELECT DesignCapacity, FullChargeCapacity FROM Win32_Battery"))
                {
                    double worst = 100; bool any = false;
                    foreach (ManagementObject mo in searcher.Get())
                    {
                        long design = Convert.ToInt64(mo["DesignCapacity"]);
                        long full = Convert.ToInt64(mo["FullChargeCapacity"]);
                        if (design > 0 && full > 0)
                        {
                            any = true;
                            double h = Math.Round((double)full / design * 100);
                            if (h < worst) worst = h;
                        }
                    }
                    if (any) hw.BatteryPct = worst;
                }
            }
            catch { }
            if (hw.DriveType == "Unknown" || !hw.SmartChecked)
                hw.Note = "Run as Administrator for full hardware diagnostics.";
            hw.DrivePoints = hw.DriveType == "SSD" ? 12 : (hw.DriveType == "HDD" ? 0 : 7);
            hw.RamPoints = hw.TotalRamGB >= 16 ? 8 : (hw.TotalRamGB >= 8 ? 5 : 0);
            if (!hw.SmartChecked) hw.HealthPoints = 5;
            else if (!hw.SmartOk) hw.HealthPoints = 0;
            else if (hw.CpuThreads < 4 || (hw.BatteryPct.HasValue && hw.BatteryPct.Value < 60)) hw.HealthPoints = 2;
            else hw.HealthPoints = 5;
            return hw;
        }

        static int GetDnsLatencyMs()
        {
            // Time one real DNS lookup. Timeout / failure = -1 (0 points).
            try
            {
                var sw = Stopwatch.StartNew();
                Dns.GetHostEntry("www.google.com");
                sw.Stop();
                return (int)sw.ElapsedMilliseconds;
            }
            catch { return -1; }
        }

        static bool TryGetUpdatesAvailable(out bool available, out int count)
        {
            // Microsoft.Update.Session COM. If it cannot be determined,
            // return false and the caller treats it as no updates pending.
            available = false; count = 0;
            try
            {
                Type t = Type.GetTypeFromProgID("Microsoft.Update.Session");
                if (t == null) return false;
                dynamic session = Activator.CreateInstance(t);
                dynamic searcher = session.CreateUpdateSearcher();
                dynamic result = searcher.Search("IsInstalled=0");
                count = result.Updates.Count;
                available = count > 0;
                return true;
            }
            catch (Exception ex)
            {
                Logger.Write("Windows Update check could not be completed - treating as no updates pending: " + ex.Message);
                return false;
            }
        }

        static int NonMicrosoftStartupCount()
        {
            // Scoring counts ENABLED non-Microsoft apps only. Microsoft's
            // own apps (OneDrive, Teams, Windows Security) are excluded
            // by name/command containing "Microsoft".
            int n = 0;
            foreach (var a in StartupApps)
            {
                string text = a.Name + " " + a.Command;
                if (text.IndexOf("Microsoft", StringComparison.OrdinalIgnoreCase) >= 0) continue;
                if (a.Name.StartsWith("Windows ", StringComparison.OrdinalIgnoreCase)) continue;
                n++;
            }
            return n;
        }

        static ScoreResult CalculateHealthScore(double cFreeGB, double cFreePct, double ramUsedPct,
            int startupNonMs, int cpuPct, double uptimeDays, double junkGB, bool pendingRestart,
            bool updatesAvailable, double recycleGB, int dnsMs, string osDriveType,
            double totalRamGB, bool smartOk, bool smartChecked, int cpuThreads, double? batteryPct)
        {
            // Exact port of Syed's calculate_health_score (SCORE_SPEC_75_25.md).
            var b = new Dictionary<string, int>();
            if (cFreeGB >= 40 || cFreePct >= 20) b["c_drive"] = 20;
            else if (cFreeGB >= 25 || cFreePct >= 15) b["c_drive"] = 15;
            else if (cFreeGB >= 15 || cFreePct >= 10) b["c_drive"] = 10;
            else if (cFreeGB >= 5 || cFreePct >= 5) b["c_drive"] = 5;
            else b["c_drive"] = 0;
            b["ram_pressure"] = ramUsedPct < 65 ? 15 : (ramUsedPct < 80 ? 10 : (ramUsedPct < 90 ? 5 : 0));
            b["startup"] = startupNonMs <= 3 ? 12 : (startupNonMs <= 6 ? 8 : (startupNonMs <= 10 ? 4 : 0));
            int cpuPts = cpuPct < 40 ? 5 : (cpuPct < 70 ? 3 : (cpuPct < 85 ? 1 : 0));
            int upPts = uptimeDays < 3 ? 5 : (uptimeDays < 7 ? 3 : (uptimeDays < 14 ? 1 : 0));
            b["cpu_uptime"] = cpuPts + upPts;
            b["cpu_points"] = cpuPts; b["uptime_points"] = upPts;
            b["junk"] = junkGB < 0.5 ? 8 : (junkGB < 2.0 ? 6 : (junkGB < 5.0 ? 3 : 0));
            b["updates"] = pendingRestart ? 0 : (updatesAvailable ? 4 : 6);
            int rbPts = recycleGB < 0.5 ? 2 : (recycleGB <= 2.0 ? 1 : 0);
            int dnsPts = dnsMs < 0 ? 0 : (dnsMs < 50 ? 2 : (dnsMs <= 150 ? 1 : 0));
            b["recycle_dns"] = rbPts + dnsPts;
            b["recycle_points"] = rbPts; b["dns_points"] = dnsPts;
            b["hw_drive"] = osDriveType == "SSD" ? 12 : (osDriveType == "HDD" ? 0 : 7);
            b["hw_ram"] = totalRamGB >= 16 ? 8 : (totalRamGB >= 8 ? 5 : 0);
            if (!smartChecked) b["hw_health"] = 5;
            else if (!smartOk) b["hw_health"] = 0;
            else if (cpuThreads < 4 || (batteryPct.HasValue && batteryPct.Value < 60)) b["hw_health"] = 2;
            else b["hw_health"] = 5;
            int software = b["c_drive"] + b["ram_pressure"] + b["startup"] + b["cpu_uptime"] + b["junk"] + b["updates"] + b["recycle_dns"];
            int hardware = b["hw_drive"] + b["hw_ram"] + b["hw_health"];
            int total = software + hardware;
            string cap = null;
            if (smartChecked && !smartOk && total > 39)
            {
                total = 39;
                cap = "Hard drive failure risk detected — backup data first!";
            }
            else if (cFreeGB < 2.0 && total > 44)
            {
                total = 44;
                cap = "C: drive has under 2 GB free — critical risk of Windows slowdown/errors.";
            }
            int instant = (8 - b["junk"]) + (2 - rbPts) + (2 - dnsPts) + (12 - b["startup"]);
            return new ScoreResult
            {
                Total = total, Grade = Grade(total), Verdict = Verdict(total),
                Software = software, Hardware = hardware, CapReason = cap,
                InstantFixable = instant, Breakdown = b
            };
        }

        static List<StartupApp> GetStartupApps()
        {
            var apps = new List<StartupApp>();
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            Action<string, string, string> add = (name, command, location) =>
            {
                if (string.IsNullOrEmpty(name)) name = "(unnamed)";
                if (command == null) command = "";
                string key = name + "|" + command;
                if (seen.Contains(key)) return;
                seen.Add(key);
                apps.Add(new StartupApp { Name = name, Command = command, Location = location,
                    DisableSelected = (location == "HKCU Run") });
            };
            // 1. WMI Win32_StartupCommand
            try
            {
                using (var searcher = new ManagementObjectSearcher("SELECT Name, Command, Location FROM Win32_StartupCommand"))
                {
                    foreach (ManagementObject mo in searcher.Get())
                    {
                        try
                        {
                            add(Convert.ToString(mo["Name"]), Convert.ToString(mo["Command"]),
                                Convert.ToString(mo["Location"]) ?? "WMI");
                        }
                        catch { }
                    }
                }
            }
            catch { }
            // 2. Run keys: HKCU Run is the only source v1 can disable.
            AddRunKey(Registry.CurrentUser, @"Software\Microsoft\Windows\CurrentVersion\Run", "HKCU Run", add);
            AddRunKey(Registry.LocalMachine, @"SOFTWARE\Microsoft\Windows\CurrentVersion\Run", "HKLM Run", add);
            AddRunKey(Registry.LocalMachine, @"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run", "HKLM Run (32-bit)", add);
            // 3. Startup folders (info only in v1)
            string userStartup = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                @"Microsoft\Windows\Start Menu\Programs\Startup");
            string allStartup = Path.Combine(Util.ProgramData,
                @"Microsoft\Windows\Start Menu\Programs\StartUp");
            AddStartupFolder(userStartup, "Startup Folder (user)", add);
            AddStartupFolder(allStartup, "Startup Folder (all users)", add);
            return apps;
        }

        static void AddRunKey(RegistryKey hive, string subKey, string location, Action<string, string, string> add)
        {
            try
            {
                using (var key = hive.OpenSubKey(subKey, false))
                {
                    if (key == null) return;
                    foreach (string name in key.GetValueNames())
                    {
                        try { add(name, Convert.ToString(key.GetValue(name)), location); }
                        catch { }
                    }
                }
            }
            catch { }
        }

        static void AddStartupFolder(string path, string location, Action<string, string, string> add)
        {
            try
            {
                if (!Directory.Exists(path)) return;
                foreach (string f in Directory.GetFiles(path))
                    add(Path.GetFileNameWithoutExtension(f), f, location);
            }
            catch { }
        }

        public static Diagnosis Diagnose()
        {
            JunkFiles = new List<FileInfo>();
            StartupApps = new List<StartupApp>();
            var diag = new Diagnosis();

            // CPU + RAM first: averaged over 3-5 sec (never a 1-sec
            // snapshot - ProFix itself spikes CPU on launch).
            int cpuPct; double ramUsedPct; long totalMem, freeMem;
            SampleCpuRam(out cpuPct, out ramUsedPct, out totalMem, out freeMem);
            double uptimeDays = 0;
            try
            {
                using (var searcher = new ManagementObjectSearcher("SELECT LastBootUpTime FROM Win32_OperatingSystem"))
                {
                    foreach (ManagementObject mo in searcher.Get())
                    {
                        DateTime boot = ManagementDateTimeConverter.ToDateTime(Convert.ToString(mo["LastBootUpTime"]));
                        uptimeDays = Math.Round((DateTime.Now - boot).TotalDays, 1);
                    }
                }
            }
            catch { try { uptimeDays = Math.Round(Environment.TickCount64 / 86400000.0, 1); } catch { } }

            // 1. Junk files - ProClean sources: Temp 24h, Browser 0h,
            //    Logs 168h, Shader 168h, Error Reports 168h.
            var junkFiles = new List<FileInfo>();
            Util.CollectFiles(new[] { Util.TempPath, Path.Combine(Util.WinDir, "Temp") }, 24, junkFiles);
            Util.CollectFiles(Util.GetBrowserCachePaths().ToArray(), 0, junkFiles);
            Util.CollectFiles(new[] { Path.Combine(Util.WinDir, "Logs"), Path.Combine(Util.WinDir, "Panther") }, 168, junkFiles);
            Util.CollectFiles(new[]
            {
                Path.Combine(Util.LocalAppData, "D3DSCache"),
                Path.Combine(Util.LocalAppData, @"NVIDIA\DXCache"),
                Path.Combine(Util.LocalAppData, @"AMD\DxCache")
            }, 168, junkFiles);
            Util.CollectFiles(new[]
            {
                Path.Combine(Util.ProgramData, @"Microsoft\Windows\WER\ReportArchive"),
                Path.Combine(Util.ProgramData, @"Microsoft\Windows\WER\ReportQueue"),
                Path.Combine(Util.LocalAppData, @"Microsoft\Windows\WER\ReportArchive")
            }, 168, junkFiles);
            JunkFiles = junkFiles;
            long junkSize = 0;
            foreach (var f in junkFiles) junkSize += f.Length;
            double junkGB = Math.Round(junkSize / (1024.0 * 1024 * 1024), 2);
            int junkPts = junkGB < 0.5 ? 8 : (junkGB < 2.0 ? 6 : (junkGB < 5.0 ? 3 : 0));
            string detail = string.Format("{0} files, {1} reclaimable", junkFiles.Count, Util.FormatSize(junkSize));
            if (Util.IsBrowserRunning()) detail += " - browser is running, close it for a full clean";
            diag.Items["Junk"] = new DiagItem { Name = "Junk Files",
                Status = junkPts == 8 ? "Good" : (junkPts == 0 ? "Bad" : "Warning"),
                Detail = detail, Fix = "Clean junk files",
                Points = junkPts, MaxPoints = 8, Delta = junkPts - 8 };

            // 2. C: drive free space (dual GB OR % rule)
            long freeBytes = 0, totalBytes = 1;
            try
            {
                var drive = new DriveInfo("C");
                freeBytes = drive.TotalFreeSpace;
                totalBytes = Math.Max(1, drive.TotalSize);
            }
            catch { }
            double pctFree = Math.Round((double)freeBytes / totalBytes * 100, 1);
            double cFreeGB = Math.Round(freeBytes / (1024.0 * 1024 * 1024), 1);
            int cPts = (cFreeGB >= 40 || pctFree >= 20) ? 20 : ((cFreeGB >= 25 || pctFree >= 15) ? 15
                : ((cFreeGB >= 15 || pctFree >= 10) ? 10 : ((cFreeGB >= 5 || pctFree >= 5) ? 5 : 0)));
            diag.Items["DriveC"] = new DiagItem { Name = "C: Drive Free Space",
                Status = cPts == 20 ? "Good" : (cPts >= 10 ? "Warning" : "Bad"),
                Detail = string.Format("{0} free of {1} ({2}% free)", Util.FormatSize(freeBytes), Util.FormatSize(totalBytes), pctFree),
                Fix = "No automatic fix - free space or move files off C:",
                Points = cPts, MaxPoints = 20, Delta = cPts - 20 };

            // 3. Startup apps - scoring counts non-Microsoft only, UI lists all
            StartupApps = GetStartupApps();
            int hkcuCount = 0;
            foreach (var a in StartupApps) if (a.Location == "HKCU Run") hkcuCount++;
            int nonMsCount = NonMicrosoftStartupCount();
            int stPts = nonMsCount <= 3 ? 12 : (nonMsCount <= 6 ? 8 : (nonMsCount <= 10 ? 4 : 0));
            diag.Items["Startup"] = new DiagItem { Name = "Startup Apps",
                Status = stPts == 12 ? "Good" : (stPts == 0 ? "Bad" : "Warning"),
                Detail = string.Format("{0} startup apps ({1} non-Microsoft counted, {2} in HKCU Run - can be disabled in v1)", StartupApps.Count, nonMsCount, hkcuCount),
                Fix = "Disable selected HKCU Run apps (reversible, backed up to log)",
                Points = stPts, MaxPoints = 12, Delta = stPts - 12 };

            // 4. Memory pressure (averaged RAM %)
            int ramPts = ramUsedPct < 65 ? 15 : (ramUsedPct < 80 ? 10 : (ramUsedPct < 90 ? 5 : 0));
            diag.Items["Memory"] = new DiagItem { Name = "Memory (RAM) Pressure",
                Status = ramPts == 15 ? "Good" : (ramPts == 0 ? "Bad" : "Warning"),
                Detail = string.Format("{0}% used (3-sec avg) - {1} free of {2}", ramUsedPct, Util.FormatSize(freeMem), Util.FormatSize(totalMem)),
                Fix = "No automatic fix - close heavy apps / add RAM",
                Points = ramPts, MaxPoints = 15, Delta = ramPts - 15 };

            // 5. CPU load (5-sec avg) + Uptime
            int cpuPts = cpuPct < 40 ? 5 : (cpuPct < 70 ? 3 : (cpuPct < 85 ? 1 : 0));
            int upPts = uptimeDays < 3 ? 5 : (uptimeDays < 7 ? 3 : (uptimeDays < 14 ? 1 : 0));
            int cpuUpPts = cpuPts + upPts;
            diag.Items["CpuUptime"] = new DiagItem { Name = "CPU Load + Uptime",
                Status = cpuUpPts >= 8 ? "Good" : (cpuUpPts >= 4 ? "Warning" : "Bad"),
                Detail = string.Format("CPU {0}% (5-sec avg) - uptime {1} days", cpuPct, uptimeDays),
                Fix = "No automatic fix - restart your PC",
                Points = cpuUpPts, MaxPoints = 10, Delta = cpuUpPts - 10 };

            // 6. Windows Update / Pending reboot (report only)
            bool pending = false;
            string svcStatus = "Unknown";
            try
            {
                using (var sc = new ServiceController("wuauserv")) svcStatus = sc.Status.ToString();
            }
            catch { }
            foreach (string sub in new[]
            {
                @"SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
                @"SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
            })
            {
                try
                {
                    using (var key = Registry.LocalMachine.OpenSubKey(sub, false))
                    {
                        if (key != null) pending = true;
                    }
                }
                catch { }
            }
            try
            {
                using (var key = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Control\Session Manager", false))
                {
                    if (key != null && key.GetValue("PendingFileRenameOperations") != null) pending = true;
                }
            }
            catch { }
            bool updAvailable = false; int updCount = 0; bool updChecked = false;
            if (!pending)
            {
                Logger.Write("Checking Windows Update for pending updates (may take a few seconds)...");
                updChecked = TryGetUpdatesAvailable(out updAvailable, out updCount);
            }
            int updPts = pending ? 0 : (updAvailable ? 4 : 6);
            string updDetail = pending ? ("Restart pending (Windows Update) - wuauserv: " + svcStatus)
                : (updAvailable ? string.Format("Updates available ({0}) - no restart needed yet - wuauserv: {1}", updCount, svcStatus)
                : (updChecked ? ("No restart pending, no updates available - wuauserv: " + svcStatus)
                : ("No restart pending - Windows Update check could not be completed - wuauserv: " + svcStatus)));
            diag.Items["UpdateReboot"] = new DiagItem { Name = "Windows Update / Reboot",
                Status = updPts == 6 ? "Good" : "Warning",
                Detail = updDetail,
                Fix = "No automatic fix - restart your PC when ready",
                Points = updPts, MaxPoints = 6, Delta = updPts - 6 };

            // 7. Recycle Bin + DNS latency
            long rbCount, rbSize;
            Util.GetRecycleBinInfo(out rbCount, out rbSize);
            diag.RecycleCount = rbCount;
            diag.RecycleSize = rbSize;
            double rbGB = Math.Round(rbSize / (1024.0 * 1024 * 1024), 2);
            int rbPts = rbGB < 0.5 ? 2 : (rbGB <= 2.0 ? 1 : 0);
            int dnsMs = GetDnsLatencyMs();
            int dnsPts = dnsMs < 0 ? 0 : (dnsMs < 50 ? 2 : (dnsMs <= 150 ? 1 : 0));
            int rdPts = rbPts + dnsPts;
            string dnsText = dnsMs < 0 ? "DNS lookup failed" : string.Format("DNS {0} ms", dnsMs);
            diag.Items["RecycleDns"] = new DiagItem { Name = "Recycle Bin + DNS",
                Status = rdPts >= 3 ? "Good" : (rdPts == 0 ? "Bad" : "Warning"),
                Detail = string.Format("Recycle Bin: {0} items, {1} - {2}", rbCount, Util.FormatSize(rbSize), dnsText),
                Fix = "Empty Recycle Bin + flush DNS",
                Points = rdPts, MaxPoints = 4, Delta = rdPts - 4 };

            // Hardware (read-only WMI/CIM) - 3 rows, same numbers as the score
            var hw = GetHardwareInfo();
            diag.Items["HwDrive"] = new DiagItem { Name = "Hardware: OS Drive",
                Status = hw.DrivePoints == 12 ? "Good" : (hw.DrivePoints == 0 ? "Bad" : "Warning"),
                Detail = "OS drive type: " + hw.DriveType + (string.IsNullOrEmpty(hw.Note) ? "" : " - " + hw.Note),
                Fix = hw.DriveType == "HDD" ? "No automatic fix - SSD upgrade would speed boot 4x-5x"
                    : (hw.DriveType == "SSD" ? "No fix needed - SSD already installed"
                    : "No automatic fix - run as Administrator for full hardware diagnostics"),
                Points = hw.DrivePoints, MaxPoints = 12, Delta = hw.DrivePoints - 12 };
            diag.Items["HwRam"] = new DiagItem { Name = "Hardware: Total RAM",
                Status = hw.RamPoints == 8 ? "Good" : (hw.RamPoints == 0 ? "Bad" : "Warning"),
                Detail = string.Format("Total RAM installed: {0} GB", hw.TotalRamGB),
                Fix = hw.RamPoints == 8 ? "No fix needed - 16 GB or more"
                    : (hw.RamPoints == 5 ? "No automatic fix - 16 GB would help heavy multitasking"
                    : "No automatic fix - RAM upgrade recommended (under 8 GB)"),
                Points = hw.RamPoints, MaxPoints = 8, Delta = hw.RamPoints - 8 };
            string hwHealthDetail = !hw.SmartChecked
                ? "SMART status could not be checked (run as Administrator) - CPU threads: " + hw.CpuThreads
                : (!hw.SmartOk
                    ? "SMART WARNING - disk may be failing - back up your data first! CPU threads: " + hw.CpuThreads
                    : "SMART OK - CPU threads: " + hw.CpuThreads
                        + (hw.BatteryPct.HasValue ? " - Battery health: " + hw.BatteryPct.Value + "%" : ""));
            diag.Items["HwHealth"] = new DiagItem { Name = "Hardware: Disk + CPU",
                Status = hw.HealthPoints == 5 ? "Good" : (hw.HealthPoints == 0 ? "Bad" : "Warning"),
                Detail = hwHealthDetail,
                Fix = (!hw.SmartOk && hw.SmartChecked) ? "No automatic fix - back up your data immediately"
                    : "No automatic fix - hardware is read-only in ProFix",
                Points = hw.HealthPoints, MaxPoints = 5, Delta = hw.HealthPoints - 5 };

            // 75/25 score - exact port of calculate_health_score
            var result = CalculateHealthScore(cFreeGB, pctFree, ramUsedPct, nonMsCount,
                cpuPct, uptimeDays, junkGB, pending, updAvailable, rbGB, dnsMs,
                hw.DriveType, hw.TotalRamGB, hw.SmartOk, hw.SmartChecked, hw.CpuThreads, hw.BatteryPct);
            diag.Score = result.Total;
            diag.Grade = result.Grade;
            diag.Verdict = result.Verdict;
            diag.SoftwareScore = result.Software;
            diag.HardwareScore = result.Hardware;
            diag.CapReason = result.CapReason;
            diag.InstantFixable = result.InstantFixable;
            diag.Breakdown = result.Breakdown;
            Current = diag;
            foreach (var dg in Diagnostics)
            {
                var it = diag.Items[dg.Id];
                Logger.Write(string.Format("Diagnose: {0} - {1} | {2} ({3}) [{4}/{5} pts]",
                    it.Name, it.Status, it.Detail, it.Fix, it.Points, it.MaxPoints));
            }
            Logger.Write(string.Format("Health Score: {0} - {1} (System {2}/75 + Hardware {3}/25). {4}",
                result.Total, result.Grade, result.Software, result.Hardware, result.Verdict));
            if (!string.IsNullOrEmpty(result.CapReason)) Logger.Write("CAP APPLIED: " + result.CapReason);
            Logger.Write(string.Format("1-Click Fix se +{0} points turant badhenge.", result.InstantFixable));
            return diag;
        }

        public static void Fix(List<string> selectedIds, bool isAdmin, bool makeRestorePoint,
            ProgressBar progress, out long deleted, out long skipped, out long freed, out int disabled)
        {
            deleted = 0; skipped = 0; freed = 0; disabled = 0;
            LastFixRestorePointCreated = false;
            LastFixRecycleEmptied = false;
            LastFixDnsFlushed = false;
            LastFixDisabledEntries = new List<RestoreEntry>();
            if (Current == null)
            {
                Logger.Write("Fix called without a Diagnose - nothing done.");
                return;
            }
            if (makeRestorePoint)
            {
                Logger.Write("Creating a System Restore Point (can take ~30 seconds)...");
                LastFixRestorePointCreated = Util.CreateRestorePoint();
                if (LastFixRestorePointCreated) Logger.Write("Restore Point created.");
            }
            foreach (string id in selectedIds)
            {
                if (!Current.Items.ContainsKey(id)) continue;
                var item = Current.Items[id];
                Logger.Write("Fixing: " + item.Name + " ...");
                if (id == "Junk")
                {
                    long d2, s2, f2;
                    RemoveJunkFiles(progress, out d2, out s2, out f2);
                    deleted += d2; skipped += s2; freed += f2;
                }
                else if (id == "Startup")
                {
                    int dis, sk;
                    List<RestoreEntry> entries;
                    DisableSelectedStartupApps(out dis, out sk, out entries);
                    disabled += dis; skipped += sk;
                    LastFixDisabledEntries.AddRange(entries);
                    if (dis == 0) Logger.Write("Startup: no HKCU Run apps were selected to disable (open the Startup row to pick them, or none are in HKCU Run).");
                }
                else if (id == "RecycleDns")
                {
                    // GUI callers pass ConfirmRecycleBin via FixWithRecycle below;
                    // this overload flushes DNS only and never empties the bin.
                    LastFixDnsFlushed = Util.FlushDns();
                }
                else
                {
                    Logger.Write("No automatic fix for: " + item.Name + " - " + item.Fix);
                }
            }
            Logger.Write(string.Format("Fix done: {0} files deleted ({1} freed), {2} skipped, {3} startup apps disabled.",
                deleted, Util.FormatSize(freed), skipped, disabled));
        }

        // GUI path: same as Fix, but RecycleDns also empties the bin when
        // confirmRecycleBin is true (the GUI asks its own confirmation).
        public static void FixWithRecycle(List<string> selectedIds, bool isAdmin, bool makeRestorePoint,
            ProgressBar progress, bool confirmRecycleBin,
            out long deleted, out long skipped, out long freed, out int disabled)
        {
            deleted = 0; skipped = 0; freed = 0; disabled = 0;
            LastFixRestorePointCreated = false;
            LastFixRecycleEmptied = false;
            LastFixDnsFlushed = false;
            LastFixDisabledEntries = new List<RestoreEntry>();
            if (Current == null)
            {
                Logger.Write("Fix called without a Diagnose - nothing done.");
                return;
            }
            if (makeRestorePoint)
            {
                Logger.Write("Creating a System Restore Point (can take ~30 seconds)...");
                LastFixRestorePointCreated = Util.CreateRestorePoint();
                if (LastFixRestorePointCreated) Logger.Write("Restore Point created.");
            }
            foreach (string id in selectedIds)
            {
                if (!Current.Items.ContainsKey(id)) continue;
                var item = Current.Items[id];
                Logger.Write("Fixing: " + item.Name + " ...");
                if (id == "Junk")
                {
                    long d2, s2, f2;
                    RemoveJunkFiles(progress, out d2, out s2, out f2);
                    deleted += d2; skipped += s2; freed += f2;
                }
                else if (id == "Startup")
                {
                    int dis, sk;
                    List<RestoreEntry> entries;
                    DisableSelectedStartupApps(out dis, out sk, out entries);
                    disabled += dis; skipped += sk;
                    LastFixDisabledEntries.AddRange(entries);
                    if (dis == 0) Logger.Write("Startup: no HKCU Run apps were selected to disable (open the Startup row to pick them, or none are in HKCU Run).");
                }
                else if (id == "RecycleDns")
                {
                    if (confirmRecycleBin && Current.RecycleCount > 0)
                    {
                        try
                        {
                            uint flags = Native.SHERB_NOCONFIRMATION | Native.SHERB_NOPROGRESSUI | Native.SHERB_NOSOUND;
                            Native.SHEmptyRecycleBin(IntPtr.Zero, null, flags);
                            deleted += Current.RecycleCount;
                            freed += Current.RecycleSize;
                            LastFixRecycleEmptied = true;
                            Logger.Write("Recycle Bin emptied: " + Current.RecycleCount + " items.");
                        }
                        catch (Exception ex)
                        {
                            Logger.Write("Recycle Bin could not be emptied: " + ex.Message);
                        }
                    }
                    else if (Current.RecycleCount == 0)
                    {
                        Logger.Write("Recycle Bin already empty - nothing to empty.");
                    }
                    else
                    {
                        Logger.Write("Recycle Bin kept - user did not confirm emptying it (DNS still flushed below).");
                    }
                    LastFixDnsFlushed = Util.FlushDns();
                }
                else
                {
                    Logger.Write("No automatic fix for: " + item.Name + " - " + item.Fix);
                }
            }
            Logger.Write(string.Format("Fix done: {0} files deleted ({1} freed), {2} skipped, {3} startup apps disabled.",
                deleted, Util.FormatSize(freed), skipped, disabled));
        }

        static void RemoveJunkFiles(ProgressBar progress, out long deleted, out long skipped, out long freed)
        {
            deleted = 0; skipped = 0; freed = 0;
            int total = JunkFiles.Count, i = 0;
            foreach (var f in JunkFiles)
            {
                i++;
                if (progress != null && i % 100 == 0)
                {
                    progress.Value = Math.Min(100, (int)((double)i / Math.Max(1, total) * 100));
                    Application.DoEvents();
                }
                try
                {
                    File.Delete(f.FullName);
                    deleted++;
                    freed += f.Length;
                }
                catch { skipped++; }
            }
            Logger.Write(string.Format("Junk: {0} deleted, {1} skipped (in use or locked).", deleted, skipped));
        }

        static void DisableSelectedStartupApps(out int disabled, out int skipped, out List<RestoreEntry> entries)
        {
            disabled = 0; skipped = 0; entries = new List<RestoreEntry>();
            const string backupSub = @"Software\ProFix\DisabledStartup";
            foreach (var app in StartupApps)
            {
                if (app.Location != "HKCU Run") continue;
                if (!app.DisableSelected) continue;
                try
                {
                    using (var runKey = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", true))
                    {
                        if (runKey == null) { skipped++; continue; }
                        object value = runKey.GetValue(app.Name);
                        if (value == null) { skipped++; continue; }
                        using (var backupKey = Registry.CurrentUser.CreateSubKey(backupSub))
                        {
                            backupKey.SetValue(app.Name, value);
                        }
                        Logger.Write(string.Format("Startup backup: [{0}] = {1} (saved under HKCU\\Software\\ProFix\\DisabledStartup)", app.Name, value));
                        runKey.DeleteValue(app.Name);
                        disabled++;
                        entries.Add(new RestoreEntry
                        {
                            Name = app.Name,
                            OriginalLocation = "HKCU Run",
                            Value = Convert.ToString(value) ?? "",
                            BackupRegistryPath = @"HKCU\Software\ProFix\DisabledStartup\" + app.Name,
                            Restorable = true
                        });
                        Logger.Write("Startup disabled: " + app.Name);
                    }
                }
                catch (Exception ex)
                {
                    skipped++;
                    Logger.Write("Startup could not be disabled: " + app.Name + " - " + ex.Message);
                }
            }
        }
    }

    // ------------------------------------------------------------------
    // GUI - Windows Forms.
    // ------------------------------------------------------------------
    class MainForm : Form
    {
        ListView listView;
        TextBox txtLog;
        Label lblStatus;
        Label lblScore;
        Label lblSystem;
        Label lblHardware;
        ProgressBar barSystem;
        ProgressBar barHardware;
        ProgressBar progressBar;
        CheckBox chkRestore;
        Button btnDiagnose;
        Button btnFix;
        Button btnUndo;
        bool isAdmin;
        bool populating;

        public MainForm()
        {
            Text = "ProFix v" + Program.AppVersion + " - Slow PC Doctor";
            ClientSize = new Size(680, 702);
            StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            Font = new Font("Segoe UI", 9);
            try
            {
                string icoPath = Path.Combine(
                    Path.GetDirectoryName(Application.ExecutablePath), "ProFix.ico");
                if (File.Exists(icoPath)) Icon = new Icon(icoPath);
            }
            catch { }

            isAdmin = Util.IsAdmin();

            var lblTitle = new Label();
            lblTitle.Text = "ProFix v" + Program.AppVersion + " - Slow PC Doctor";
            lblTitle.Font = new Font("Segoe UI", 12, FontStyle.Bold);
            lblTitle.Location = new Point(12, 10);
            lblTitle.Size = new Size(656, 26);
            Controls.Add(lblTitle);

            var lblAdmin = new Label();
            lblAdmin.Text = isAdmin
                ? "Running as Administrator - all features available."
                : "Not running as Administrator - System Restore Point is disabled.";
            lblAdmin.ForeColor = isAdmin ? Color.DarkGreen : Color.DarkRed;
            lblAdmin.Location = new Point(12, 38);
            lblAdmin.Size = new Size(656, 18);
            Controls.Add(lblAdmin);

            lblScore = new Label();
            lblScore.Text = "Health Score: --  Press Diagnose to check your PC.";
            lblScore.Font = new Font("Segoe UI", 13, FontStyle.Bold);
            lblScore.Location = new Point(12, 62);
            lblScore.Size = new Size(656, 28);
            Controls.Add(lblScore);

            lblSystem = new Label();
            lblSystem.Text = "System Health: -- / 75";
            lblSystem.Location = new Point(12, 92);
            lblSystem.Size = new Size(200, 16);
            Controls.Add(lblSystem);

            barSystem = new ProgressBar();
            barSystem.Location = new Point(212, 92);
            barSystem.Size = new Size(180, 16);
            barSystem.Minimum = 0;
            barSystem.Maximum = 75;
            barSystem.Value = 0;
            Controls.Add(barSystem);

            lblHardware = new Label();
            lblHardware.Text = "Hardware Health: -- / 25";
            lblHardware.Location = new Point(402, 92);
            lblHardware.Size = new Size(200, 16);
            Controls.Add(lblHardware);

            barHardware = new ProgressBar();
            barHardware.Location = new Point(602, 92);
            barHardware.Size = new Size(66, 16);
            barHardware.Minimum = 0;
            barHardware.Maximum = 25;
            barHardware.Value = 0;
            Controls.Add(barHardware);

            listView = new ListView();
            listView.View = View.Details;
            listView.FullRowSelect = true;
            listView.GridLines = true;
            listView.CheckBoxes = true;
            listView.Location = new Point(12, 114);
            listView.Size = new Size(656, 192);
            listView.Columns.Add("Issue", 150);
            listView.Columns.Add("Status", 80);
            listView.Columns.Add("Detail", 220);
            listView.Columns.Add("Recommended Fix", 190);
            Controls.Add(listView);

            chkRestore = new CheckBox();
            chkRestore.Text = "Create a System Restore Point before fixing (recommended)";
            chkRestore.Checked = isAdmin;
            chkRestore.Enabled = isAdmin;
            chkRestore.Location = new Point(12, 316);
            chkRestore.Size = new Size(656, 22);
            Controls.Add(chkRestore);

            btnDiagnose = new Button();
            btnDiagnose.Text = "Diagnose";
            btnDiagnose.Location = new Point(12, 344);
            btnDiagnose.Size = new Size(100, 30);
            btnDiagnose.Click += BtnDiagnose_Click;
            Controls.Add(btnDiagnose);

            btnFix = new Button();
            btnFix.Text = "Fix Selected";
            btnFix.Enabled = false;
            btnFix.Location = new Point(122, 344);
            btnFix.Size = new Size(100, 30);
            btnFix.Click += BtnFix_Click;
            Controls.Add(btnFix);

            btnUndo = new Button();
            btnUndo.Text = "Undo Last Fix";
            btnUndo.Enabled = false;
            btnUndo.Location = new Point(452, 344);
            btnUndo.Size = new Size(100, 30);
            btnUndo.Click += BtnUndo_Click;
            Controls.Add(btnUndo);

            var btnSelectAll = new Button();
            btnSelectAll.Text = "Select All";
            btnSelectAll.Location = new Point(232, 344);
            btnSelectAll.Size = new Size(100, 30);
            btnSelectAll.Click += (s, e) =>
            {
                populating = true;
                foreach (ListViewItem item in listView.Items) item.Checked = true;
                populating = false;
                btnFix.Enabled = false;
                lblStatus.Text = "Selection changed - press Diagnose to refresh preview.";
            };
            Controls.Add(btnSelectAll);

            var btnClearAll = new Button();
            btnClearAll.Text = "Clear All";
            btnClearAll.Location = new Point(342, 344);
            btnClearAll.Size = new Size(100, 30);
            btnClearAll.Click += (s, e) =>
            {
                populating = true;
                foreach (ListViewItem item in listView.Items) item.Checked = false;
                populating = false;
                btnFix.Enabled = false;
                lblStatus.Text = "Selection changed - press Diagnose to refresh preview.";
            };
            Controls.Add(btnClearAll);

            progressBar = new ProgressBar();
            progressBar.Location = new Point(12, 384);
            progressBar.Size = new Size(656, 20);
            progressBar.Minimum = 0;
            progressBar.Maximum = 100;
            progressBar.Value = 0;
            Controls.Add(progressBar);

            txtLog = new TextBox();
            txtLog.Multiline = true;
            txtLog.ReadOnly = true;
            txtLog.ScrollBars = ScrollBars.Vertical;
            txtLog.Location = new Point(12, 414);
            txtLog.Size = new Size(656, 240);
            Controls.Add(txtLog);
            Logger.LogBox = txtLog;

            lblStatus = new Label();
            lblStatus.Text = "Ready. Press Diagnose to check your PC.";
            lblStatus.Location = new Point(12, 664);
            lblStatus.Size = new Size(656, 18);
            Controls.Add(lblStatus);

            listView.ItemChecked += (s, e) =>
            {
                if (populating) return;
                btnFix.Enabled = false;
                lblStatus.Text = "Selection changed - press Diagnose to refresh preview.";
            };
            listView.DoubleClick += ListView_DoubleClick;
            Engine.StatusUpdate = (text, pct) =>
            {
                lblStatus.Text = text;
                progressBar.Value = Math.Min(100, Math.Max(0, pct));
                Application.DoEvents();
            };
            Load += MainForm_Load;
        }

        void UpdateScoreDisplay(Diagnosis diag)
        {
            lblScore.Text = string.Format("Health Score: {0} - {1}", diag.Score, diag.Grade);
            lblScore.ForeColor = Engine.ScoreColor(diag.Score);
            lblSystem.Text = string.Format("System Health: {0} / 75", diag.SoftwareScore);
            lblHardware.Text = string.Format("Hardware Health: {0} / 25", diag.HardwareScore);
            barSystem.Value = Math.Min(75, Math.Max(0, diag.SoftwareScore));
            barHardware.Value = Math.Min(25, Math.Max(0, diag.HardwareScore));
        }

        void RefreshUndoButton()
        {
            try { btnUndo.Enabled = RestoreStore.HasRestorableEntries(); }
            catch { btnUndo.Enabled = false; }
        }

        void MainForm_Load(object sender, EventArgs e)
        {
            Logger.Write("ProFix v" + Program.AppVersion + " started.");
            RefreshUndoButton();
            if (!isAdmin)
            {
                var answer = MessageBox.Show(
                    "ProFix works best as Administrator (System Restore Point needs it).\n\nRestart as administrator now?",
                    "ProFix", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
                if (answer == DialogResult.Yes)
                {
                    try
                    {
                        var psi = new ProcessStartInfo();
                        psi.FileName = Application.ExecutablePath;
                        psi.UseShellExecute = true;
                        psi.Verb = "runas";
                        Process.Start(psi);
                        Application.Exit();
                    }
                    catch
                    {
                        Logger.Write("Admin restart cancelled - running without admin.");
                    }
                }
            }
        }

        List<string> GetSelectedIds()
        {
            var ids = new List<string>();
            foreach (ListViewItem item in listView.Items)
                if (item.Checked) ids.Add((string)item.Tag);
            return ids;
        }

        void UpdateResultsList()
        {
            populating = true;
            listView.Items.Clear();
            foreach (var d in Engine.Diagnostics)
            {
                if (!Engine.Current.Items.ContainsKey(d.Id)) continue;
                var it = Engine.Current.Items[d.Id];
                var row = new ListViewItem(it.Name);
                row.Tag = d.Id;
                row.Checked = d.DefaultFix;
                row.SubItems.Add(it.Status);
                row.SubItems.Add(it.Detail);
                row.SubItems.Add(it.Fix);
                listView.Items.Add(row);
            }
            populating = false;
        }

        void ListView_DoubleClick(object sender, EventArgs e)
        {
            if (listView.SelectedItems.Count == 0) return;
            ShowDetailDialog((string)listView.SelectedItems[0].Tag);
        }

        void ShowDetailDialog(string diagId)
        {
            if (Engine.Current == null) return;
            var item = Engine.Current.Items[diagId];

            if (diagId == "Junk")
            {
                var files = new List<FileInfo>(Engine.JunkFiles);
                files.Sort((a, b) => b.Length.CompareTo(a.Length));
                if (files.Count > 250) files.RemoveRange(250, files.Count - 250);
                var dlg = new Form();
                dlg.Text = "ProFix - Junk Files (largest files)";
                dlg.ClientSize = new Size(760, 480);
                dlg.StartPosition = FormStartPosition.CenterParent;
                dlg.FormBorderStyle = FormBorderStyle.FixedDialog;
                dlg.MaximizeBox = false;
                dlg.Font = new Font("Segoe UI", 9);
                var lv = new ListView();
                lv.View = View.Details;
                lv.FullRowSelect = true;
                lv.GridLines = true;
                lv.Location = new Point(12, 12);
                lv.Size = new Size(736, 400);
                lv.Columns.Add("File Path", 430);
                lv.Columns.Add("Size", 110);
                lv.Columns.Add("Last Modified", 170);
                foreach (var f in files)
                {
                    var row = new ListViewItem(f.FullName);
                    row.SubItems.Add(Util.FormatSize(f.Length));
                    row.SubItems.Add(f.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss"));
                    lv.Items.Add(row);
                }
                dlg.Controls.Add(lv);
                var lbl = new Label();
                lbl.Text = files.Count == 0 ? "No junk files found."
                    : string.Format("Top {0} largest files - read only, nothing is deleted here.", files.Count);
                lbl.Location = new Point(12, 424);
                lbl.Size = new Size(736, 18);
                dlg.Controls.Add(lbl);
                var btnClose = new Button();
                btnClose.Text = "Close";
                btnClose.Location = new Point(648, 444);
                btnClose.Size = new Size(100, 28);
                btnClose.Click += (s, ev) => dlg.Close();
                dlg.Controls.Add(btnClose);
                dlg.AcceptButton = btnClose;
                dlg.ShowDialog(this);
                return;
            }

            if (diagId == "Startup")
            {
                var dlg = new Form();
                dlg.Text = "ProFix - Startup Apps (pick HKCU Run apps to disable)";
                dlg.ClientSize = new Size(760, 480);
                dlg.StartPosition = FormStartPosition.CenterParent;
                dlg.FormBorderStyle = FormBorderStyle.FixedDialog;
                dlg.MaximizeBox = false;
                dlg.Font = new Font("Segoe UI", 9);
                var lblInfo = new Label();
                lblInfo.Text = "Tick the apps to disable. Only HKCU Run apps can be disabled in v1 (reversible - backed up to HKCU\\Software\\ProFix\\DisabledStartup). HKLM Run and Startup Folder apps are shown for info only.";
                lblInfo.Location = new Point(12, 12);
                lblInfo.Size = new Size(736, 36);
                dlg.Controls.Add(lblInfo);
                var clb = new CheckedListBox();
                clb.CheckOnClick = true;
                clb.Location = new Point(12, 54);
                clb.Size = new Size(736, 360);
                foreach (var a in Engine.StartupApps)
                {
                    int idx = clb.Items.Add(string.Format("{0}  [{1}]  {2}", a.Name, a.Location, a.Command));
                    if (a.Location == "HKCU Run") clb.SetItemChecked(idx, a.DisableSelected);
                }
                dlg.Controls.Add(clb);
                var btnOk = new Button();
                btnOk.Text = "OK - Save Selection";
                btnOk.Location = new Point(548, 428);
                btnOk.Size = new Size(200, 28);
                btnOk.Click += (s, ev) =>
                {
                    for (int i = 0; i < clb.Items.Count && i < Engine.StartupApps.Count; i++)
                    {
                        var a = Engine.StartupApps[i];
                        if (a.Location == "HKCU Run") a.DisableSelected = clb.GetItemChecked(i);
                    }
                    dlg.Close();
                };
                dlg.Controls.Add(btnOk);
                dlg.AcceptButton = btnOk;
                dlg.ShowDialog(this);
                return;
            }

            string text = string.Format(
                "{0}\nStatus: {1}\nDetail: {2}\nRecommended fix: {3}\nScore: {4} / {5} points\n1-Click Fix se +{6} points turant badhenge.\n\n{7}",
                item.Name, item.Status, item.Detail, item.Fix, item.Points, item.MaxPoints, Engine.Current.InstantFixable, Engine.Current.Verdict);
            MessageBox.Show(text, "ProFix - " + item.Name,
                MessageBoxButtons.OK, MessageBoxIcon.Information);
        }

        void BtnDiagnose_Click(object sender, EventArgs e)
        {
            btnDiagnose.Enabled = false;
            btnFix.Enabled = false;
            progressBar.Value = 0;
            lblStatus.Text = "Diagnosing... measuring CPU/RAM (3-5 sec average)";
            Application.DoEvents();
            txtLog.Clear();
            Logger.Write("ProFix v" + Program.AppVersion + " - diagnose started.");
            try
            {
                var diag = Engine.Diagnose();
                UpdateResultsList();
                UpdateScoreDisplay(diag);
                lblStatus.Text = string.Format("Diagnosed: {0} - {1} (System {2}/75 + Hardware {3}/25). 1-Click Fix se +{4} points turant badhenge. Tick issues, then press Fix Selected.",
                    diag.Score, diag.Grade, diag.SoftwareScore, diag.HardwareScore, diag.InstantFixable);
                btnFix.Enabled = true;
                RefreshUndoButton();
            }
            catch (Exception ex)
            {
                lblStatus.Text = "Diagnose failed: " + ex.Message;
                Logger.Write("Diagnose failed: " + ex.Message);
            }
            finally
            {
                btnDiagnose.Enabled = true;
                progressBar.Value = 0;
            }
        }

        void BtnUndo_Click(object sender, EventArgs e)
        {
            var entries = RestoreStore.GetRestorableEntries();
            if (entries == null || entries.Count == 0)
            {
                MessageBox.Show("No undo available - no startup apps were disabled by the last fix, or the restore backup is missing or corrupt.",
                    "ProFix - Undo Last Fix", MessageBoxButtons.OK, MessageBoxIcon.Information);
                RefreshUndoButton();
                return;
            }
            var names = new List<string>();
            foreach (var en in entries) names.Add(en.Name);
            var ok = MessageBox.Show(
                "Restore these startup apps disabled by the last fix?\n\n" + string.Join(", ", names.ToArray()) +
                "\n\nDeleted junk files cannot be restored - use the System Restore Point created before fixing if needed.",
                "ProFix - Undo Last Fix", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
            if (ok != DialogResult.Yes) return;
            int restored, failed;
            List<string> restoredNames;
            string undonePath;
            RestoreStore.UndoLastFix(out restored, out failed, out restoredNames, out undonePath);
            RefreshUndoButton();
            if (restored > 0)
            {
                try
                {
                    var diag = Engine.Diagnose();
                    UpdateResultsList();
                    UpdateScoreDisplay(diag);
                    lblStatus.Text = string.Format("Undo done - re-diagnosed: {0} - {1}.", diag.Score, diag.Grade);
                    btnFix.Enabled = true;
                }
                catch (Exception ex)
                {
                    Logger.Write("Re-diagnose after undo failed: " + ex.Message);
                }
            }
            MessageBox.Show(
                string.Format("Restored {0} startup apps. Deleted junk files cannot be restored - use the System Restore Point created before fixing if needed.\n\nFailed: {1}",
                    restored, failed),
                "ProFix - Undo", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }

        void BtnFix_Click(object sender, EventArgs e)
        {
            if (Engine.Current == null)
            {
                MessageBox.Show("Press Diagnose first.", "ProFix",
                    MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }
            int scoreBefore = Engine.Current.Score;
            string gradeBefore = Engine.Current.Grade;
            int softwareBefore = Engine.Current.SoftwareScore;
            int hardwareBefore = Engine.Current.HardwareScore;
            long recycleCountBefore = Engine.Current.RecycleCount;
            var ids = GetSelectedIds();
            if (ids.Count == 0)
            {
                MessageBox.Show("Tick at least one issue first.", "ProFix",
                    MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }
            string msg = "Fix the ticked issues?\n\nJunk files are deleted PERMANENTLY - they do not go to the Recycle Bin.\nStartup apps are disabled (reversible - backed up).\nReview the list above first.";
            var ok = MessageBox.Show(msg, "ProFix - confirm fix",
                MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
            if (ok != DialogResult.Yes) return;

            bool confirmBin = false;
            if (ids.Contains("RecycleDns") && Engine.Current.RecycleCount > 0)
            {
                var ok2 = MessageBox.Show("Empty the Recycle Bin too? This cannot be undone. (DNS will still be flushed.)",
                    "ProFix - Recycle Bin", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
                if (ok2 == DialogResult.Yes) confirmBin = true;
            }

            btnDiagnose.Enabled = false;
            btnFix.Enabled = false;
            lblStatus.Text = "Fixing...";
            try
            {
                long deleted, skipped, freed;
                int disabled;
                Engine.FixWithRecycle(ids, isAdmin, chkRestore.Checked, progressBar, confirmBin,
                    out deleted, out skipped, out freed, out disabled);
                long recycleItemsForReport = Engine.LastFixRecycleEmptied ? recycleCountBefore : 0;
                RestoreStore.WriteRestoreJson(scoreBefore, gradeBefore, deleted, freed, recycleItemsForReport, softwareBefore, hardwareBefore);
                var after = Engine.Diagnose();
                UpdateResultsList();
                UpdateScoreDisplay(after);
                var disabledNames = new List<string>();
                foreach (var en in Engine.LastFixDisabledEntries) disabledNames.Add(en.Name);
                string reportPath = Report.WriteBeforeAfterReport(scoreBefore, gradeBefore, after,
                    deleted, freed, disabledNames, Engine.LastFixRecycleEmptied, recycleItemsForReport,
                    Engine.LastFixDnsFlushed, Engine.LastFixRestorePointCreated, softwareBefore, hardwareBefore);
                RefreshUndoButton();
                btnFix.Enabled = true;
                lblStatus.Text = string.Format("Done: Health Score {0} -> {1}, {2} files deleted ({3} freed), {4} startup apps disabled. Report: {5}",
                    scoreBefore, after.Score, deleted, Util.FormatSize(freed), disabled, reportPath);
                MessageBox.Show(
                    string.Format("Fix complete.\n\nHealth Score: {0} -> {1}\nDeleted: {2} files ({3})\nSkipped (in use): {4}\nStartup apps disabled: {5}\n\nReport saved to:\n{6}\n\nLog saved to:\n{7}",
                        scoreBefore, after.Score, deleted, Util.FormatSize(freed), skipped, disabled, reportPath, Logger.LogPath),
                    "ProFix", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            catch (Exception ex)
            {
                lblStatus.Text = "Fix failed: " + ex.Message;
                Logger.Write("Fix failed: " + ex.Message);
            }
            finally
            {
                btnDiagnose.Enabled = true;
                progressBar.Value = 0;
            }
        }
    }
}
