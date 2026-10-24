param(
  [string]$Targets = 'DeepSeek Harness',
  [int]$IntervalMs = 4000,
  [switch]$Once
)

$ErrorActionPreference = 'Continue'
$logPath = Join-Path $env:TEMP 'dsh-a11y-warmup.log'

# One watcher per user session: a second copy (another host process loading the
# same profile) exits immediately instead of duplicating every scan.
# The lock file is the primary guard: the OS releases it even on a hard kill.
$lockPath = Join-Path $env:TEMP 'dsh-a11y-warmup.lock'
try {
  $lock = [System.IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
} catch {
  exit 0
}
$mutex = New-Object System.Threading.Mutex($false, 'Global\dsh-a11y-warmup')
try {
  if (-not $mutex.WaitOne(0)) { exit 0 }
} catch [System.Threading.AbandonedMutexException] {
  # Previous watcher died without releasing: we own it now.
}

function Write-Log([string]$m) {
  try { "$(Get-Date -Format 'HH:mm:ss') $m" | Out-File -FilePath $logPath -Append -Encoding ascii } catch {}
}

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class A11yWarm {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr h, EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet = CharSet.Ansi)] static extern int GetClassNameA(IntPtr h, StringBuilder sb, int n);
  [DllImport("user32.dll")] static extern IntPtr SendMessageTimeout(IntPtr h, uint msg, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr result);

  public static Dictionary<IntPtr, uint> TopWindows() {
    var d = new Dictionary<IntPtr, uint>();
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (pid != 0) d[h] = pid;
      return true;
    }, IntPtr.Zero);
    return d;
  }

  public static IntPtr[] RenderersOf(IntPtr parent) {
    var list = new List<IntPtr>();
    EnumChildWindows(parent, delegate(IntPtr c, IntPtr l) {
      var sb = new StringBuilder(256);
      GetClassNameA(c, sb, 256);
      if (sb.ToString() == "Chrome_RenderWidgetHostHWND") list.Add(c);
      return true;
    }, IntPtr.Zero);
    return list.ToArray();
  }

  // WM_GETOBJECT (0x003D) with UiaRootObjectId (-25): what an accessibility client sends.
  public static int Ping(IntPtr h) {
    IntPtr r;
    IntPtr ok = SendMessageTimeout(h, 0x003D, IntPtr.Zero, new IntPtr(-25), 2, 1500, out r);
    return (int)ok.ToInt64();
  }

  public static bool Alive(IntPtr h) { return IsWindow(h); }
}
'@ -ErrorAction Stop

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

# WM_GETOBJECT switches Chromium's accessibility mode on, but the web content
# only becomes visible once a UI Automation client attaches to the renderer
# window and actually walks it. Deep walks are what make the content appear in
# the parent window's tree as well, so the first touch is a full descendant
# walk; later touches are shallow keepalives.
function Connect-Uia([IntPtr]$h, [switch]$Deep) {
  try {
    $el = [System.Windows.Automation.AutomationElement]::FromHandle($h)
    if ($null -eq $el) { return -1 }
    $scope = if ($Deep) {
      [System.Windows.Automation.TreeScope]::Descendants
    } else {
      [System.Windows.Automation.TreeScope]::Children
    }
    $found = $el.FindAll($scope, [System.Windows.Automation.Condition]::TrueCondition)
    return $found.Count
  } catch {
    return -1
  }
}

$targetNames = @($Targets -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
$seen = @{}
$attached = @{}
$deep = @{}
$deepAt = @{}
$procNameCache = @{}
Write-Log "start targets=$($targetNames -join '|') interval=$IntervalMs once=$($Once.IsPresent)"

while ($true) {
  try {
    foreach ($pair in [A11yWarm]::TopWindows().GetEnumerator()) {
      $hwnd = $pair.Key
      $procId = [int]$pair.Value
      if (-not $procNameCache.ContainsKey($procId)) {
        try { $procNameCache[$procId] = (Get-Process -Id $procId -ErrorAction Stop).ProcessName.ToLowerInvariant() }
        catch { $procNameCache[$procId] = '' }
      }
      if ($targetNames -notcontains $procNameCache[$procId]) { continue }
      foreach ($r in [A11yWarm]::RenderersOf($hwnd)) {
        $key = $r.ToInt64()
        $now = [DateTime]::UtcNow
        $first = -not $seen.ContainsKey($key)
        if ($first) { $null = [A11yWarm]::Ping($r) }

        # Deep walk until the renderer reports content; shallow keepalive after.
        $deepDue = (-not $deep.ContainsKey($key)) -or ($deep[$key] -le 0 -and (-not $deepAt.ContainsKey($key) -or ($now - $deepAt[$key]).TotalSeconds -ge 10))
        $stale = (-not $attached.ContainsKey($key)) -or (($now - $attached[$key]).TotalSeconds -ge 45)
        if ($deepDue) {
          $count = Connect-Uia $r -Deep
          $deep[$key] = $count
          $deepAt[$key] = $now
          $attached[$key] = $now
          $seen[$key] = $true
          Write-Log "deep renderer=$key hwnd=$($hwnd.ToInt64()) proc=$procId nodes=$count"
        } elseif ($stale) {
          $count = Connect-Uia $r
          $attached[$key] = $now
          $seen[$key] = $true
          Write-Log "keepalive renderer=$key nodes=$count"
        }
      }
    }
  } catch {
    Write-Log "loop error: $($_.Exception.Message)"
  }
  if ($Once) { break }
  Start-Sleep -Milliseconds $IntervalMs
}
Write-Log "exit seen=$($seen.Count)"
