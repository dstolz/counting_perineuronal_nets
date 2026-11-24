<#
.SYNOPSIS
Run the MATLAB tests of counting_perineuronal_nets (tests\t*.m) on a hidden Windows desktop.

.DESCRIPTION
Starts MATLAB (bin\matlab.exe -wait ... -batch "run_all_tests(...)") on a desktop of its own that is never
shown (Win32 CreateDesktop "counting_pnn_tests"), so the figures and apps the tests open are drawn there and
never come over your windows or take the focus. -Visible runs MATLAB on your desktop instead, to watch.

MATLAB's output (its -logfile) is echoed to the console while it grows. The run ends with a PASS/FAIL summary
and exits with
    0    every test passed
    1    one or more tests failed
    2    runner or launch error (no MATLAB, nothing matched, MATLAB died before reporting)
    3    a dialog waits for a person (an ACTION NEEDED block says which window)
    124  killed at -TimeoutMin

MATLAB uses its own preferences folder, %LOCALAPPDATA%\counting_perineuronal_nets\test_prefs\<run>, deleted
after the run, so the tests never read or write your real MATLAB preferences (the Cell* GUIs persist their
settings with setpref).

Dialogs that wait for a person: nobody can answer one on the hidden desktop. The run looks for them every
-DialogSec seconds (run_all_tests prints a "[needs you]" line when uiwait / questdlg / uigetfile / ... has
waited that long; the native dialogs, class #32770, of the run's processes are looked for from here), prints
an ACTION NEEDED block naming the window, and stops the run (exit 3). Under -batch MATLAB refuses its own
blocking dialogs ("Creating dialog boxes that block execution is not supported"); that is reported too.
To answer one yourself, run that test with -Visible -Interactive.

.PARAMETER Name
Test class names or wildcard patterns to run (default: every tests\t*.m class): tFixture, 'tCuration*',
or 'tFixture/testFilesExist' for one test method.

.PARAMETER IncludeSlow
Also run tests tagged Slow, Python or Benchmark (left out by default).

.PARAMETER Visible
Run MATLAB on your desktop, so the windows the tests open can be watched (they come over your windows).

.PARAMETER Interactive
Use -r instead of -batch so MATLAB's blocking dialogs wait for your answer. Only meaningful with -Visible
(implies it).

.PARAMETER DialogSec
Seconds a dialog may wait before it counts as waiting for a person (default 30).

.PARAMETER TimeoutMin
Minutes after which MATLAB and its child processes are killed (exit 124). Default 20.

.PARAMETER MatlabRoot
MATLAB installation folder (default C:\Program Files\MATLAB\R2025a).

.PARAMETER LogDir
Folder for the log and results CSV of the run (default %LOCALAPPDATA%\counting_perineuronal_nets\test_logs).

.PARAMETER WithoutClient
Start MATLAB with CELLDB_NO_CLIENT=1: celldb.available is false whatever is installed, as on a computer without the
CarasLabDB checkout. The tests that need the lab database client (tCelldbClient, the client states of
tCelldbInvariance) are then reported as skipped, and the rest must pass without it.

.PARAMETER DryRun
Print the MATLAB command line and run nothing.

.EXAMPLE
tools\Run-Tests.ps1
tools\Run-Tests.ps1 tFixture
tools\Run-Tests.ps1 'tCuration*' -IncludeSlow
tools\Run-Tests.ps1 tFixture -Visible
tools\Run-Tests.ps1 tSomeDialogTest -Visible -Interactive
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)] [string[]] $Name = @(),
    [switch] $IncludeSlow,
    [switch] $Visible,
    [switch] $Interactive,
    [switch] $WithoutClient,
    [ValidateRange(5, 3600)] [int] $DialogSec = 30,
    [ValidateRange(1, 1440)] [int] $TimeoutMin = 20,
    [string] $MatlabRoot = 'C:\Program Files\MATLAB\R2025a',
    [string] $LogDir = '',
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
if ($Interactive) { $Visible = [switch]::Present }

$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$testsDir = Join-Path $repo 'tests'
$appData = Join-Path $env:LOCALAPPDATA 'counting_perineuronal_nets'
if (-not $LogDir) { $LogDir = Join-Path $appData 'test_logs' }
$prefsRoot = Join-Path $appData 'test_prefs'
foreach ($d in @($LogDir, $prefsRoot)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force $d | Out-Null } }

$exe = Join-Path $MatlabRoot 'bin\matlab.exe'
if (-not (Test-Path $exe)) { Write-Host "MATLAB not found: $exe (see -MatlabRoot)"; exit 2 }
if (-not (Test-Path (Join-Path $testsDir 'run_all_tests.m'))) { Write-Host "tests\run_all_tests.m not found under $repo"; exit 2 }

# ---- the MATLAB command ----------------------------------------------------------------------------

function ConvertTo-MatlabChar([string] $s) { return "'" + $s.Replace("'", "''") + "'" }

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$log = Join-Path $LogDir "$stamp.log"
$csv = Join-Path $LogDir "$stamp.csv"
$names = @()
foreach ($n in $Name) { foreach ($p in ($n -split '[\s,]+')) { if ($p) { $names += $p } } }

$opts = @()
if (-not $IncludeSlow) { $opts += "ExcludeTag={'Slow','Python','Benchmark'}" }
$opts += "DialogSec=$DialogSec"
$opts += "ResultsCSV=$(ConvertTo-MatlabChar $csv)"
$nameArg = ''
if ($names.Count -gt 0) { $nameArg = '{' + (($names | ForEach-Object { ConvertTo-MatlabChar $_ }) -join ',') + '}, ' }
$cmd = "cd($(ConvertTo-MatlabChar $repo)); addpath($(ConvertTo-MatlabChar $testsDir)); run_all_tests($nameArg$($opts -join ', '));"

function Get-MatlabArgs {
    if ($Interactive) {
        # -r lets MATLAB's blocking dialogs wait for an answer; exit 1 on an error as -batch does
        $rCmd = "try, $cmd; catch e, fprintf(2, '%s\n', getReport(e)); exit(1); end; exit(0)"
        return @('-wait', '-nodesktop', '-nosplash', '-minimize', '-logfile', "`"$log`"", '-r', "`"$rCmd`"")
    }
    return @('-wait', '-logfile', "`"$log`"", '-batch', "`"$cmd`"")
}

if ($DryRun) {
    Write-Host "`"$exe`" $((Get-MatlabArgs) -join ' ')"
    exit 0
}

# ---- the hidden desktop ----------------------------------------------------------------------------

$HiddenDesktopSource = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

// A process started on a desktop that is never shown: its windows (and its children's, which inherit
// the desktop) cannot come over the user's windows or take the focus. Id, HasExited and ExitCode
// as on System.Diagnostics.Process. DialogWindows finds the native dialogs (class #32770: file
// pickers, message boxes) that given processes show, on that desktop or on the user's.
public class CellTestDesktop {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO {
        public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateDesktop(string name, IntPtr device, IntPtr devmode, int flags, uint access, IntPtr sa);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CreateProcess(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit,
        uint flags, IntPtr env, string dir, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr h, out uint code);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumDesktopWindows(IntPtr desk, EnumWindowsProc fn, IntPtr lParam);
    [DllImport("user32.dll")] static extern IntPtr GetThreadDesktop(uint threadId);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr hwnd, StringBuilder s, int n);

    const uint GENERIC_ALL = 0x10000000, CREATE_NEW_CONSOLE = 0x10;
    const int STARTF_USESHOWWINDOW = 1; const short SW_HIDE = 0;
    static IntPtr desktop = IntPtr.Zero;   // held open for the life of this PowerShell

    IntPtr handle;
    public int Id { get; private set; }

    public static CellTestDesktop Start(string desktopName, string commandLine) {
        if (desktop == IntPtr.Zero) {
            desktop = CreateDesktop(desktopName, IntPtr.Zero, IntPtr.Zero, 0, GENERIC_ALL, IntPtr.Zero);
            if (desktop == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }
        var si = new STARTUPINFO();
        si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
        si.lpDesktop = @"WinSta0\" + desktopName;
        si.dwFlags = STARTF_USESHOWWINDOW; si.wShowWindow = SW_HIDE;
        PROCESS_INFORMATION pi;
        if (!CreateProcess(null, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero, false,
                CREATE_NEW_CONSOLE, IntPtr.Zero, null, ref si, out pi))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        CloseHandle(pi.hThread);
        var p = new CellTestDesktop();
        p.handle = pi.hProcess; p.Id = pi.dwProcessId;
        return p;
    }
    public bool HasExited { get { return WaitForSingleObject(handle, 0) == 0; } }
    public int ExitCode { get { uint c; GetExitCodeProcess(handle, out c); return unchecked((int)c); } }

    // the titles of the visible native dialogs of processes PIDS, on the hidden desktop or on the user's
    public static string[] DialogWindows(int[] pids, bool onHidden) {
        var found = new System.Collections.Generic.List<string>();
        IntPtr desk = onHidden ? desktop : GetThreadDesktop(GetCurrentThreadId());
        if (desk == IntPtr.Zero) return found.ToArray();
        var want = new System.Collections.Generic.HashSet<int>(pids);
        EnumDesktopWindows(desk, (hwnd, l) => {
            uint pid; GetWindowThreadProcessId(hwnd, out pid);
            if (!want.Contains((int)pid) || !IsWindowVisible(hwnd)) return true;
            var cls = new StringBuilder(64); GetClassName(hwnd, cls, cls.Capacity);
            if (cls.ToString() != "#32770") return true;
            var title = new StringBuilder(256); GetWindowText(hwnd, title, title.Capacity);
            found.Add(title.ToString());
            return true;
        }, IntPtr.Zero);
        return found.ToArray();
    }
}
'@
if (-not ('CellTestDesktop' -as [type])) { Add-Type -TypeDefinition $HiddenDesktopSource -Language CSharp }

function Start-Matlab($argList) {
    # MATLAB on the hidden desktop (default) or on the user's, hidden console either way; the environment
    # (MATLAB_PREFDIR) is this process's
    if ($Visible) { return Start-Process -FilePath $exe -ArgumentList $argList -PassThru -WindowStyle Hidden }
    return [CellTestDesktop]::Start('counting_pnn_tests', "`"$exe`" " + ($argList -join ' '))
}

function Get-ProcessTree($rootId) {
    # the ids of process ROOTID and all its descendants
    $all = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId -ErrorAction SilentlyContinue)
    $ids = @([int]$rootId); $i = 0
    while ($i -lt $ids.Count) {
        foreach ($p in $all) { if ($p.ParentProcessId -eq $ids[$i] -and $ids -notcontains [int]$p.ProcessId) { $ids += [int]$p.ProcessId } }
        $i++
    }
    return [int[]]$ids
}

function Stop-MatlabTree($launcherId) {
    # the launcher (bin\matlab.exe), the MATLAB.exe it started and that one's helpers (MATLABWindow.exe)
    $ids = Get-ProcessTree $launcherId
    [array]::Reverse($ids)
    foreach ($id in $ids) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
}

# ---- watching the run ------------------------------------------------------------------------------

$state = @{ Offset = 0; Tail = ''; Needs = $false; Told = @{}; NativeSince = @{}; LastNativeCheck = (Get-Date); Proc = $null }

function Show-ActionNeeded([string] $title, [string] $what, [string] $where, [switch] $Refused) {
    $bar = '!' * 100
    Write-Host ''
    Write-Host $bar -ForegroundColor Yellow
    Write-Host '!!  ACTION NEEDED: a test is waiting for an answer from a person' -ForegroundColor Yellow
    if ($title) { Write-Host "!!  window:  `"$title`"" -ForegroundColor Yellow }
    Write-Host "!!  dialog:  $what" -ForegroundColor Yellow
    if ($where) { Write-Host "!!  where:   $where" -ForegroundColor Yellow }
    $rerun = 'tools\Run-Tests.ps1 ' + (($names | ForEach-Object { "'$_'" }) -join ' ') + ' -Visible -Interactive'
    if ($Interactive) {
        Write-Host '!!  Answer it on your screen now (the window named above); the run goes on once you have.' -ForegroundColor Yellow
    } elseif ($Refused) {
        Write-Host '!!  Under -batch MATLAB cannot show it, so the test failed (exit 3). To answer it yourself:' -ForegroundColor Yellow
        Write-Host "!!    $rerun" -ForegroundColor Yellow
    } else {
        Write-Host '!!  Nobody can answer it on the hidden desktop, so this run stops (exit 3). To answer it yourself:' -ForegroundColor Yellow
        Write-Host "!!    $rerun" -ForegroundColor Yellow
    }
    Write-Host $bar -ForegroundColor Yellow
    $state.Needs = $true
}

function Find-WaitingDialogs([string] $txt) {
    # the "[needs you]" lines run_all_tests prints, MATLAB's refusals under -batch and (every 10 s) the
    # native dialogs of the run's processes; each is reported once
    $lines = ($state.Tail + $txt) -split "`r?`n"
    $state.Tail = $lines[-1]
    $complete = @(); if ($lines.Count -gt 1) { $complete = $lines[0..($lines.Count - 2)] }
    foreach ($line in $complete) {
        if ($line -match '^\[needs you\] (.*)$') {
            $parts = $matches[1] -split ' \| '
            $first = $parts[0]
            $title = ''
            if ($first -match '"([^"]*)"') { $title = $matches[1] }
            $where = (@($parts | Select-Object -Skip 1) | Where-Object { $_ }) -join '; '
            if (-not $state.Told.ContainsKey($line)) { $state.Told[$line] = $true; Show-ActionNeeded $title $first $where }
        } elseif ($line -match 'Creating dialog boxes that block execution is not supported' -and -not $state.Told.ContainsKey('refused')) {
            $state.Told['refused'] = $true
            Show-ActionNeeded '' 'one of MATLAB''s own blocking dialogs (questdlg, uiconfirm, uigetfile, ...)' `
                'the failure report above (its stack names the code that asked)' -Refused
        }
    }
    if (((Get-Date) - $state.LastNativeCheck).TotalSeconds -ge 10) {
        $state.LastNativeCheck = Get-Date
        $titles = @([CellTestDesktop]::DialogWindows((Get-ProcessTree $state.Proc.Id), -not $Visible))
        foreach ($k in @($state.NativeSince.Keys)) { if ($titles -notcontains $k) { $state.NativeSince.Remove($k) } }
        foreach ($t in $titles) {
            if (-not $state.NativeSince.ContainsKey($t)) { $state.NativeSince[$t] = Get-Date; continue }
            if (((Get-Date) - $state.NativeSince[$t]).TotalSeconds -ge $DialogSec -and -not $state.Told.ContainsKey("native:$t")) {
                $state.Told["native:$t"] = $true
                Show-ActionNeeded $t 'a Windows dialog (a file picker or message box)' ''
            }
        }
    }
}

function Read-NewText {
    if (-not (Test-Path $log)) { return '' }
    $fs = [IO.File]::Open($log, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        if ($fs.Length -le $state.Offset) { return '' }
        [void] $fs.Seek($state.Offset, [IO.SeekOrigin]::Begin)
        $buf = New-Object byte[] ($fs.Length - $state.Offset)
        $n = $fs.Read($buf, 0, $buf.Length)
        $state.Offset += $n
        return [Text.Encoding]::UTF8.GetString($buf, 0, $n)
    } finally { $fs.Dispose() }
}

# ---- run -------------------------------------------------------------------------------------------

$prefDir = Join-Path $prefsRoot "${stamp}_$PID"
New-Item -ItemType Directory -Force $prefDir | Out-Null
$env:MATLAB_PREFDIR = $prefDir
if ($WithoutClient) { $env:CELLDB_NO_CLIENT = '1' }
# prefs folders of runs that died without cleaning up
Get-ChildItem $prefsRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) } |
    ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host "Tests: $(if ($names.Count) { $names -join ' ' } else { 'all' })$(if ($IncludeSlow) { ' (including Slow/Python/Benchmark)' })"
Write-Host "Desktop: $(if ($Visible) { 'YOUR desktop (-Visible)' } else { 'hidden (counting_pnn_tests)' }); timeout $TimeoutMin min; log: $log"

$started = Get-Date
$exitCode = 2
try {
    $state.Proc = Start-Matlab (Get-MatlabArgs)
    $deadline = $started.AddMinutes($TimeoutMin)
    while ($true) {
        $txt = Read-NewText
        if ($txt) { Write-Host -NoNewline $txt }
        Find-WaitingDialogs $txt
        if ($state.Proc.HasExited) {
            $exitCode = $state.Proc.ExitCode
            $txt = Read-NewText
            if ($txt) { Write-Host -NoNewline $txt; Find-WaitingDialogs ($txt + "`n") }
            break
        }
        if ($state.Needs -and -not $Interactive) {
            Write-Host "`nStopping MATLAB $($state.Proc.Id): a dialog needs a person (see above)."
            Stop-MatlabTree $state.Proc.Id
            $exitCode = 3
            break
        }
        if ((Get-Date) -gt $deadline) {
            Write-Host "`nTimeout after $TimeoutMin min: killing MATLAB $($state.Proc.Id)."
            Stop-MatlabTree $state.Proc.Id
            $exitCode = 124
            break
        }
        Start-Sleep -Milliseconds 1000
    }
} catch {
    Write-Host "Runner error: $($_.Exception.Message)"
    $exitCode = 2
} finally {
    # nothing of the run may outlive it
    if ($state.Proc -and -not $state.Proc.HasExited) { Stop-MatlabTree $state.Proc.Id }
    Remove-Item $prefDir -Recurse -Force -ErrorAction SilentlyContinue
}

# ---- verdict ---------------------------------------------------------------------------------------

# run_all_tests ends its output with "[results] tests=N passed=N failed=N incomplete=N seconds=S"
$res = $null
if (Test-Path $log) {
    $line = Get-Content $log | Where-Object { $_ -match '^\[results\] ' } | Select-Object -Last 1
    if ($line -match 'tests=(\d+) passed=(\d+) failed=(\d+) incomplete=(\d+)') {
        $res = @{ Tests = [int]$matches[1]; Passed = [int]$matches[2]; Failed = [int]$matches[3]; Incomplete = [int]$matches[4] }
    }
}
if ($exitCode -notin 3, 124) {
    if ($res -and $res.Failed -gt 0) { $exitCode = 1 }
    elseif ($exitCode -ne 0) { $exitCode = if ($res) { 1 } else { 2 } }
    elseif (-not $res) { $exitCode = 2 }
}
$elapsed = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
$counts = ''
if ($res) { $counts = " ($($res.Passed) passed, $($res.Failed) failed, $($res.Incomplete) skipped of $($res.Tests) tests)" }
$verdict = switch ($exitCode) {
    0 { 'PASS' } 1 { 'FAIL' } 3 { 'ACTION NEEDED (a dialog waits for a person; see above)' }
    124 { 'TIMEOUT' } default { 'ERROR (the runner or MATLAB failed before reporting; see the log)' }
}
Write-Host ("`n{0}{1} in {2} s (exit {3}); log: {4}" -f $verdict, $counts, $elapsed, $exitCode, $log)
exit $exitCode
