# 静默删除到回收站：用 Windows Shell 的 SHFileOperation，
# 带 ALLOWUNDO(进回收站)+NOCONFIRMATION+NOERRORUI+SILENT 标志，全程零弹框。
$script:shellOpCode = @"
using System;
using System.Runtime.InteropServices;
namespace DiskCleaner {
  public static class ShellFileOp {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    private struct SHFILEOPSTRUCT {
      public IntPtr hwnd;
      public uint wFunc;
      [MarshalAs(UnmanagedType.LPWStr)] public string pFrom;
      [MarshalAs(UnmanagedType.LPWStr)] public string pTo;
      public ushort fFlags;
      public int fAnyOperationsAborted;
      public IntPtr hNameMappings;
      [MarshalAs(UnmanagedType.LPWStr)] public string lpszProgressTitle;
    }
    [DllImport("shell32.dll", CharSet=CharSet.Unicode)]
    private static extern int SHFileOperation(ref SHFILEOPSTRUCT FileOp);

    public static int Recycle(string path) {
      SHFILEOPSTRUCT fs = new SHFILEOPSTRUCT();
      fs.wFunc = 0x0003;            // FO_DELETE
      fs.pFrom = path + "\0\0";     // 必须双 null 结尾
      // FOF_ALLOWUNDO|FOF_NOCONFIRMATION|FOF_NOERRORUI|FOF_SILENT
      fs.fFlags = 0x0040 | 0x0010 | 0x0400 | 0x0004;
      return SHFileOperation(ref fs);
    }
  }
}
"@
if (-not ([System.Management.Automation.PSTypeName]'DiskCleaner.ShellFileOp').Type) {
    Add-Type -TypeDefinition $script:shellOpCode
}

# Restart Manager：问 Windows「哪个进程正占用着这个文件」。
# 这是安装程序用来提示「请先关闭 XXX」的同一套官方 API，系统自带 rstrtmgr.dll。
$script:rmCode = @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace DiskCleaner {
  public static class RestartManager {
    [StructLayout(LayoutKind.Sequential)]
    struct RM_UNIQUE_PROCESS { public int dwProcessId; public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime; }
    const int CCH_RM_MAX_APP_NAME = 255;
    const int CCH_RM_MAX_SVC_NAME = 63;
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    struct RM_PROCESS_INFO {
      public RM_UNIQUE_PROCESS Process;
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst=CCH_RM_MAX_APP_NAME+1)] public string strAppName;
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst=CCH_RM_MAX_SVC_NAME+1)] public string strServiceShortName;
      public uint ApplicationType;
      public uint AppStatus;
      public uint TSSessionId;
      [MarshalAs(UnmanagedType.Bool)] public bool bRestartable;
    }
    [DllImport("rstrtmgr.dll", CharSet=CharSet.Unicode)]
    static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags, string strSessionKey);
    [DllImport("rstrtmgr.dll")]
    static extern int RmEndSession(uint pSessionHandle);
    [DllImport("rstrtmgr.dll", CharSet=CharSet.Unicode)]
    static extern int RmRegisterResources(uint pSessionHandle, uint nFiles, string[] rgsFilenames,
      uint nApplications, RM_UNIQUE_PROCESS[] rgApplications, uint nServices, string[] rgsServiceNames);
    [DllImport("rstrtmgr.dll")]
    static extern int RmGetList(uint dwSessionHandle, out uint pnProcInfoNeeded, ref uint pnProcInfo,
      [In, Out] RM_PROCESS_INFO[] rgAffectedApps, ref uint lpdwRebootReasons);

    public static int[] GetLockingProcessIds(string path) {
      var pids = new List<int>();
      uint handle;
      if (RmStartSession(out handle, 0, Guid.NewGuid().ToString()) != 0) return pids.ToArray();
      try {
        string[] resources = new string[] { path };
        if (RmRegisterResources(handle, (uint)resources.Length, resources, 0, null, 0, null) != 0) return pids.ToArray();
        uint needed = 0, count = 0, reasons = 0;
        int r = RmGetList(handle, out needed, ref count, null, ref reasons);
        if (r == 234 /*ERROR_MORE_DATA*/ && needed > 0) {
          var info = new RM_PROCESS_INFO[needed];
          count = needed;
          if (RmGetList(handle, out needed, ref count, info, ref reasons) == 0) {
            for (int i = 0; i < count; i++) pids.Add(info[i].Process.dwProcessId);
          }
        }
      } finally { RmEndSession(handle); }
      return pids.ToArray();
    }
  }
}
"@
if (-not ([System.Management.Automation.PSTypeName]'DiskCleaner.RestartManager').Type) {
    try { Add-Type -TypeDefinition $script:rmCode } catch { }
}

# 关键系统进程：碰了会让系统不稳定甚至蓝屏，绝不结束。
$script:protectedNames = @(
    'System','Idle','Registry','smss','csrss','wininit','winlogon','services','lsass',
    'svchost','dwm','fontdrvhost','LsaIso','MemCompression','WUDFHost','ctfmon',
    'explorer'   # 桌面/任务栏，关了会闪退重启，太扰民——清理时遇它占用就跳过
)

function Stop-OccupyingBrowser {
    # 结束 Chrome / Edge 进程，便于清理它们的缓存（缓存文件常被浏览器占用）
    foreach ($name in 'chrome', 'msedge') {
        Get-Process -Name $name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 600   # 等进程退出、释放文件句柄
}

function Get-LockingProcess {
    # 返回正占用 $Path 的进程列表：@{ Id; Name; Protected }
    param([Parameter(Mandatory)][string]$Path)
    $ids = @()
    try { $ids = [DiskCleaner.RestartManager]::GetLockingProcessIds((Convert-Path -LiteralPath $Path -ErrorAction SilentlyContinue)) } catch { $ids = @() }
    $out = @()
    foreach ($procId in ($ids | Select-Object -Unique)) {
        if ($procId -eq 0 -or $procId -eq $PID) { continue }
        try { $p = Get-Process -Id $procId -ErrorAction Stop } catch { continue }
        $out += [PSCustomObject]@{
            Id        = $procId
            Name      = $p.ProcessName
            Protected = ($script:protectedNames -contains $p.ProcessName)
        }
    }
    $out
}

function Stop-LockingProcess {
    # 关掉占用 $Path 的进程（系统关键进程除外），返回关掉的进程名（去重）
    param([Parameter(Mandatory)][string]$Path)
    $killed = @()
    foreach ($p in (Get-LockingProcess -Path $Path)) {
        if ($p.Protected) { continue }
        try { Stop-Process -Id $p.Id -Force -ErrorAction Stop; $killed += $p.Name } catch { }
    }
    if ($killed.Count -gt 0) { Start-Sleep -Milliseconds 500 }   # 等句柄释放
    @($killed | Select-Object -Unique)
}

function Invoke-Recycle {
    param([string]$Path)
    try { return [DiskCleaner.ShellFileOp]::Recycle((Convert-Path -LiteralPath $Path)) } catch { return -1 }
}

function Remove-ToRecycleBin {
    # 静默删到回收站(可找回)；删不掉且 -Force 时：自动关掉占用它的进程再删。
    # 返回 @{ Success; Path; Error; Forced; Killed }
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Force
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        return [PSCustomObject]@{ Success=$false; Path=$Path; Error='路径不存在'; Forced=$false; Killed=@() }
    }
    # 1) 先静默删到回收站
    if ((Invoke-Recycle $Path) -eq 0) {
        return [PSCustomObject]@{ Success=$true; Path=$Path; Error=$null; Forced=$false; Killed=@() }
    }
    if (-not $Force) {
        return [PSCustomObject]@{ Success=$false; Path=$Path; Error='删到回收站失败（多半被占用）'; Forced=$false; Killed=@() }
    }
    # 2) -Force：先试强制永久删
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        return [PSCustomObject]@{ Success=$true; Path=$Path; Error=$null; Forced=$true; Killed=@() }
    } catch { }
    # 3) 还删不掉：八成被进程占用——找出并关掉占用进程，再删一次
    $killed = @(Stop-LockingProcess -Path $Path)
    if ((Invoke-Recycle $Path) -eq 0) {
        return [PSCustomObject]@{ Success=$true; Path=$Path; Error=$null; Forced=$false; Killed=$killed }
    }
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        return [PSCustomObject]@{ Success=$true; Path=$Path; Error=$null; Forced=$true; Killed=$killed }
    } catch {
        return [PSCustomObject]@{ Success=$false; Path=$Path; Error=$_.Exception.Message; Forced=$true; Killed=$killed }
    }
}

Export-ModuleMember -Function Remove-ToRecycleBin, Stop-OccupyingBrowser, Get-LockingProcess, Stop-LockingProcess
