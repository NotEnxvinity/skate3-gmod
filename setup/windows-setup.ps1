# S3GM (Skate 3 in Garry's Mod) setup for Windows. The Windows twin of
# skate3-setup.sh; S3GM-setup-Windows.bat starts it.
#
#   drag your Skate 3 .iso onto S3GM-setup-Windows.bat     fills in the disc
#   double-click S3GM-setup-Windows.bat                    finds an .iso beside
#                                                          it, if there is one
#   S3GM-setup-Windows.bat --game "D:\Skate 3\skate3.iso"  [--gmod <folder>]
#
# Either way a small window shows the Garry's Mod folder and disc it found,
# so the player checks or changes them before anything runs. After Install
# the same window shows the progress and the result: setup starts itself
# again without a console, so the .bat's black window closes right away
# (set S3GM_CONSOLE=1 to keep everything in the console instead). Everything
# it prints also goes to %LOCALAPPDATA%\skate3-gmod\setup-log.txt.
#
# This installs the S3GM addon and skate module into Garry's Mod and converts
# what it needs from the disc. Nothing needs installing first:
# without a Python 3.10 to 3.13 on the computer, the first run downloads
# Python's own portable build (the "python" package Python publishes on
# NuGet) into %LOCALAPPDATA%\skate3-gmod, along with the Skate 3 engine's
# converters, vgmstream, and numpy and Pillow in a private environment.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# A PYTHONHOME or PYTHONPATH left in the environment by some other program
# points the portable Python at the wrong standard library ("No module named
# 'encodings'"). Only this window loses them.
foreach ($name in @('PYTHONHOME', 'PYTHONPATH', 'PYTHONSTARTUP', 'PYTHONUSERBASE', 'PYTHONEXECUTABLE', 'PYTHONSAFEPATH')) {
    Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
}

# Runs a program only to ask it something: its output, or $null when it
# fails in any way. With errors set to stop, a program that merely writes to
# stderr (py.exe listing its Pythons when a version is missing) would
# otherwise end the whole setup.
function Ask($exe, [string[]]$arguments) {
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $exe @arguments 2>$null
        if ($LASTEXITCODE -eq 0) { return ("$out").Trim() }
    } catch {}
    return $null
}

# True when this Python starts and has what the setup needs from it: the
# standard library (encodings), venv and pip's installer, and ssl for pip.
function PythonWorks($exe, [string[]]$flags) {
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { return $false }
    return ((Ask $exe ($flags + @('-I', '-c', 'import encodings, venv, ensurepip, ssl; print(1)'))) -eq '1')
}

# One argument as Windows programs read their command line.
function Quote([string]$text) {
    if ($text -and $text -notmatch '[\s"]') { return $text }
    $text = [regex]::Replace($text, '(\\*)"', { param($m) $m.Groups[1].Value * 2 + '\"' })
    $text = [regex]::Replace($text, '(\\+)$', { param($m) $m.Groups[1].Value * 2 })
    return '"' + $text + '"'
}

# Started from the .bat: start again without a console window (the setup
# window shows the progress), so the .bat's black window closes. Programs
# this one runs share its hidden console, so none of them pops one up either.
if (-not $env:S3GM_WINDOWED -and -not $env:S3GM_CONSOLE) {
    try {
        $env:S3GM_WINDOWED = '1'
        $info = New-Object System.Diagnostics.ProcessStartInfo
        $info.FileName = (Get-Process -Id $PID).Path
        $info.Arguments = (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath) + @($args) |
            ForEach-Object { Quote "$_" }) -join ' '
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        [void][System.Diagnostics.Process]::Start($info)
        exit 0
    } catch {
        # Couldn't: carry on in the console as before.
        Remove-Item -LiteralPath Env:S3GM_WINDOWED -ErrorAction SilentlyContinue
    }
}

# The engine revision the skate host was built from (the same as skate3-setup.sh).
$EngineRev = 'cb7968930f14dad38457e98720d1a274e469eec2'
# Python's portable Windows build, published by Python itself on NuGet.
$PythonVersion = '3.13.16'
$PythonZip = "https://api.nuget.org/v3-flatcontainer/python/$PythonVersion/python.$PythonVersion.nupkg"
$EngineZip = "https://github.com/SK8-ENGINE/skate-3-rust-engine/archive/$EngineRev.zip"
$VgmstreamZip = 'https://github.com/vgmstream/vgmstream-releases/releases/download/nightly/vgmstream-win64.zip'

$here = $PSScriptRoot
# The folder the player opened: the download keeps this script in
# S3GM-setup\setup-files, with only the launcher and README above it.
$top = $here
if ((Split-Path $here -Leaf) -eq 'setup-files') { $top = Split-Path $here -Parent }
$env:PYTHONDONTWRITEBYTECODE = '1'
# The S3GM version this setup installs, shown in its windows.
$version = ''
try { $version = (Get-Content -LiteralPath (Join-Path $here 'VERSION') -Raw -ErrorAction Stop).Trim() } catch {}
$cache = Join-Path $env:LOCALAPPDATA 'skate3-gmod'
New-Item -ItemType Directory -Force -Path $cache | Out-Null

$logFile = Join-Path $cache 'setup-log.txt'
try { Set-Content -LiteralPath $logFile -Value "S3GM $version setup, $(Get-Date)" } catch {}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$form = $null
$logBox = $null
$installing = $false
$running = $null
$runOutput = @()

# Keeps the window answering while setup works.
function Pump {
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 30
}

# A line of progress: the console, the log file, and the window's log.
function Say([string]$text) {
    Write-Host $text
    try { Add-Content -LiteralPath $logFile -Value $text } catch {}
    if ($script:logBox) {
        $script:logBox.AppendText($text + "`r`n")
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Die($message) {
    Say "error: $message"
    $message = "$message`n`nEverything setup printed is in $logFile"
    if ($script:logBox -and $script:form.Visible) {
        # Keep the window, with its log, until the player closes it.
        $script:installing = $false
        $script:bar.Style = 'Continuous'
        $script:bar.Value = 0
        $script:status.ForeColor = [System.Drawing.Color]::DarkRed
        $script:status.Text = "Setup stopped: $message"
        $script:finish.Text = 'Close'
        $script:finish.Visible = $true
        [void][System.Windows.Forms.MessageBox]::Show($script:form, $message, 'S3GM setup', 'OK', 'Error')
        while ($script:form.Visible) { Pump }
    } else {
        [void][System.Windows.Forms.MessageBox]::Show($message, 'S3GM setup', 'OK', 'Error')
    }
    exit 1
}
# Anything that stops the script unexpectedly still says why (there may be no console to read).
trap { Die "Setup stopped on an unexpected error: $($_.Exception.Message)" }

# Downloads $url to $file while the window keeps answering; throws when it fails.
function Download($url, $file) {
    $client = New-Object System.Net.WebClient
    $task = $client.DownloadFileTaskAsync($url, $file)
    $next = [DateTime]::Now
    while (-not $task.IsCompleted) {
        if ($script:status -and [DateTime]::Now -ge $next -and (Test-Path -LiteralPath $file)) {
            $mb = [math]::Round((Get-Item -LiteralPath $file).Length / 1MB)
            $script:status.Text = "$($script:step) ($mb MB so far)"
            $next = [DateTime]::Now.AddSeconds(1)
        }
        Pump
    }
    $client.Dispose()
    if ($task.IsFaulted) { throw $task.Exception.InnerException }
    if ($task.IsCanceled) { throw 'the download was cancelled' }
}

# Unpacks a zip in the background while the window keeps answering; throws when it fails.
function Unzip($zip, $dest) {
    $job = Start-Job -ScriptBlock {
        param($z, $d)
        $ProgressPreference = 'SilentlyContinue'
        Expand-Archive -LiteralPath $z -DestinationPath $d -Force
    } -ArgumentList $zip, $dest
    while ($job.State -eq 'NotStarted' -or $job.State -eq 'Running') { Pump }
    try { [void](Receive-Job -Job $job -ErrorAction Stop) } finally { Remove-Job -Job $job -Force }
}

# A step's heading: in the log and on the window's status line.
function Step($text) {
    $script:step = $text
    if ($script:status) { $script:status.Text = $text }
    Say $text
}

# Runs a program with no window of its own, its output going to the log as
# it comes. Returns its exit code; $runOutput holds its lines.
function Run($exe, [string[]]$arguments) {
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $exe
    $info.Arguments = ($arguments | ForEach-Object { Quote $_ }) -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $info.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $info.EnvironmentVariables['PYTHONUNBUFFERED'] = '1'
    $info.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'
    $process = [System.Diagnostics.Process]::Start($info)
    $script:running = $process
    $lines = New-Object System.Collections.Generic.List[string]
    $out = $process.StandardOutput.ReadLineAsync()
    $err = $process.StandardError.ReadLineAsync()
    while ($out -or $err) {
        $got = $false
        if ($out -and $out.IsCompleted) {
            $got = $true
            if ($null -eq $out.Result) { $out = $null } else { Say $out.Result; $lines.Add($out.Result); $out = $process.StandardOutput.ReadLineAsync() }
        }
        if ($err -and $err.IsCompleted) {
            $got = $true
            if ($null -eq $err.Result) { $err = $null } else { Say $err.Result; $lines.Add($err.Result); $err = $process.StandardError.ReadLineAsync() }
        }
        if (-not $got) { Pump }
    }
    $process.WaitForExit()
    $script:running = $null
    $script:runOutput = $lines.ToArray()
    return $process.ExitCode
}

# Downloads Python's portable build into $portable, replacing whatever is
# there, and checks it can start. Stops with a message that names the cause
# when it can't.
function FetchPython {
    Step "Fetching Python $PythonVersion for the converters (one time, nothing is installed)..."
    $zip = Join-Path $cache 'python.zip'
    $partial = "$portable.partial"
    # A copy a stopped run left half done would swallow the new one.
    foreach ($old in @($portable, $partial)) {
        if (Test-Path -LiteralPath $old) {
            try { Remove-Item -LiteralPath $old -Recurse -Force }
            catch { Die "Couldn't remove the old Python folder $old : $($_.Exception.Message) Close anything using it (an antivirus scan, a Python window), delete $cache by hand, then run this again." }
        }
    }
    try { Download $PythonZip $zip }
    catch { Die "Downloading Python from nuget.org failed: $($_.Exception.Message) Check the internet connection, then run this again." }
    try { Unzip $zip $partial }
    catch { Die "Unpacking Python failed: $($_.Exception.Message) An antivirus may have blocked it: allow the folder $cache, then run this again." }
    # Expand-Archive can leave files out without saying so; the .NET unzipper
    # fills in what is missing.
    if (-not (Test-Path -LiteralPath (Join-Path $partial 'tools\Lib\encodings\__init__.py'))) {
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            Remove-Item -LiteralPath $partial -Recurse -Force -ErrorAction SilentlyContinue
            [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $partial)
        } catch {}
    }
    Remove-Item -LiteralPath $zip -Force
    Move-Item -LiteralPath $partial -Destination $portable
    if (-not (Test-Path -LiteralPath $portableExe)) {
        Die "Python was fetched, but $portableExe is missing. An antivirus may have removed it: allow the folder $cache, delete it, then run this again."
    }
    if (-not (PythonWorks $portableExe @())) {
        $why = ''
        if (-not (Test-Path -LiteralPath (Join-Path $portable 'tools\Lib\encodings\__init__.py'))) {
            $why = "Its Lib folder came out empty, which is what an antivirus does when it quarantines Python's files."
        }
        # Python's own words, for the console and for a screenshot.
        $ErrorActionPreference = 'Continue'
        Say (& $portableExe -I -c 'import encodings, venv, ensurepip, ssl' 2>&1 | ForEach-Object { "$_" } | Out-String)
        Die "Python was fetched but won't start. $why Allow the folder $cache in your antivirus (Windows Security > Virus & threat protection > Manage settings > Exclusions), delete the folder, then run this again."
    }
}

# What to convert: a disc image dragged onto the .bat, --game, an .iso (or
# extracted default.xex) sitting beside the setup, or one picked in the window.
$rest = @()
$game = $null
$gmod = $null
for ($i = 0; $i -lt $args.Count; $i++) {
    if ($args[$i] -eq '--game' -and $i + 1 -lt $args.Count) { $game = $args[$i + 1]; $i++ }
    elseif ($args[$i] -eq '--gmod' -and $i + 1 -lt $args.Count) { $gmod = $args[$i + 1]; $i++ }
    elseif ($args[$i] -notlike '--*' -and -not $game -and (Test-Path -LiteralPath $args[$i])) { $game = $args[$i] }
    else { $rest += $args[$i] }
}
if (-not $game) {
    $parent = Split-Path $top -Parent
    $beside = @(Get-ChildItem -LiteralPath $top, $parent -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -eq '.iso' -or $_.Name -eq 'default.xex' })
    # An extracted game in a folder of its own beside the setup.
    $beside += @(Get-ChildItem -LiteralPath $parent -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'default.xex' } | Where-Object { Test-Path -LiteralPath $_ } |
        ForEach-Object { Get-Item -LiteralPath $_ })
    if ($beside.Count -eq 1) { $game = $beside[0].FullName }
}

# The garrysmod folder inside whatever was given (garrysmod itself, GarrysMod,
# a Steam library or a drive), or $null. Only a real install counts: a folder
# an uninstall left behind has no gameinfo.txt.
function GarrysmodIn($folder) {
    if (-not $folder) { return $null }
    foreach ($sub in @('', 'garrysmod', 'GarrysMod\garrysmod', 'common\GarrysMod\garrysmod', 'steamapps\common\GarrysMod\garrysmod',
                       'SteamLibrary\steamapps\common\GarrysMod\garrysmod', 'Steam\steamapps\common\GarrysMod\garrysmod')) {
        $candidate = if ($sub) { Join-Path $folder $sub } else { $folder }
        if (Test-Path -LiteralPath (Join-Path $candidate 'gameinfo.txt') -PathType Leaf) {
            return (Get-Item -LiteralPath $candidate).FullName
        }
    }
    return $null
}

# Only a first guess for the window below: the Gmod this setup was unpacked
# into, else the first real install in any Steam library on any drive.
function FindGmod {
    $folder = $here
    while ($folder) {
        if ((Split-Path $folder -Leaf) -eq 'garrysmod' -and (GarrysmodIn $folder)) { return $folder }
        $folder = Split-Path $folder -Parent
    }
    $roots = @()
    foreach ($key in @(@('HKCU:\Software\Valve\Steam', 'SteamPath'), @('HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'InstallPath'),
                       @('HKLM:\SOFTWARE\Valve\Steam', 'InstallPath'))) {
        try { $value = (Get-ItemProperty -LiteralPath $key[0] -ErrorAction Stop).($key[1]); if ($value) { $roots += $value } } catch {}
    }
    foreach ($drive in @([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady })) {
        foreach ($name in @('Steam', 'SteamLibrary', 'Steam Library', 'Program Files (x86)\Steam', 'Program Files\Steam',
                            'Games\Steam', 'Games\SteamLibrary')) { $roots += (Join-Path $drive.RootDirectory.FullName $name) }
    }
    $libraries = @()
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $libraries += $root
        foreach ($vdf in @((Join-Path $root 'steamapps\libraryfolders.vdf'), (Join-Path $root 'config\libraryfolders.vdf'))) {
            if (-not (Test-Path -LiteralPath $vdf -PathType Leaf)) { continue }
            try { $text = Get-Content -LiteralPath $vdf -Raw -ErrorAction Stop } catch { continue }
            foreach ($m in [regex]::Matches($text, '"path"\s+"([^"]+)"')) { $libraries += $m.Groups[1].Value.Replace('\\', '\') }
        }
    }
    foreach ($library in $libraries) {
        $found = GarrysmodIn (Join-Path $library 'steamapps\common\GarrysMod\garrysmod')
        if ($found) { return $found }
    }
    return $null
}

# Like the old setup app: one small window with both folders filled in as
# best we can, so the player checks them (and fixes them) before anything runs.
if ($gmod) { $gmod = GarrysmodIn $gmod }
if (-not $gmod) { try { $gmod = FindGmod } catch { $gmod = $null } }
[System.Windows.Forms.Application]::EnableVisualStyles()
$form = New-Object System.Windows.Forms.Form -Property @{
    Text = ("S3GM $version setup" -replace '  ', ' '); Width = 640; Height = 330; AutoScroll = $true; FormBorderStyle = 'FixedDialog'; MaximizeBox = $false
    MinimizeBox = $false; StartPosition = 'CenterScreen'
}
# Come to the front once when it opens (a .bat's window can open behind
# others), then be a normal window that other apps can cover.
$form.Add_Shown({ $form.TopMost = $true; $form.Activate(); $form.TopMost = $false })
function AddRow($y, $label, $value) {
    $form.Controls.Add((New-Object System.Windows.Forms.Label -Property @{ Text = $label; Left = 16; Top = $y; Width = 590; Height = 20 }))
    $box = New-Object System.Windows.Forms.TextBox -Property @{ Left = 16; Top = $y + 22; Width = 490; Text = "$value" }
    $form.Controls.Add($box)
    $button = New-Object System.Windows.Forms.Button -Property @{ Text = 'Browse...'; Left = 516; Top = $y + 20; Width = 90 }
    $form.Controls.Add($button)
    return @($box, $button)
}
$gmodBox, $gmodBrowse = AddRow 14 'Your garrysmod folder (lowercase, the one INSIDE GarrysMod: ...\steamapps\common\GarrysMod\garrysmod)' $gmod
$gameBox, $gameBrowse = AddRow 74 'Your Skate 3 (Xbox 360) disc image (.iso), or default.xex in an extracted copy' $game
$gmodBrowse.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Select the garrysmod folder (inside GarrysMod). The GarrysMod folder or your Steam library folder works too.'
    if ($gmodBox.Text -and (Test-Path -LiteralPath $gmodBox.Text)) { $dialog.SelectedPath = $gmodBox.Text }
    if ($dialog.ShowDialog($form) -eq 'OK') {
        $picked = GarrysmodIn $dialog.SelectedPath
        $gmodBox.Text = if ($picked) { $picked } else { $dialog.SelectedPath }
    }
})
$gameBrowse.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = 'Select your Skate 3 (Xbox 360) disc image, or default.xex'
    $dialog.Filter = 'Skate 3 disc image (*.iso;default.xex)|*.iso;default.xex|All files (*.*)|*.*'
    if ($dialog.ShowDialog($form) -eq 'OK') { $gameBox.Text = $dialog.FileName }
})
# On for the test builds: the retail-sound engine needs the cache it makes, and
# the old sounds stay as the fallback either way.
$engineBox = New-Object System.Windows.Forms.CheckBox -Property @{
    Text = "Skate 3's own sound engine (beta): also prepare its sounds from your disc. Needs a few GB of free space and a few more minutes."
    Left = 16; Top = 134; Width = 590; Height = 44; Checked = $true }
$form.Controls.Add($engineBox)
$ok = New-Object System.Windows.Forms.Button -Property @{ Text = 'Install'; Left = 420; Top = 200; Width = 90; Height = 30 }
$cancel = New-Object System.Windows.Forms.Button -Property @{ Text = 'Cancel'; Left = 516; Top = 200; Width = 90; Height = 30; DialogResult = 'Cancel' }
$form.Controls.Add((New-Object System.Windows.Forms.Label -Property @{
    Text = 'Check both, then press Install. This window shows the progress.'; Left = 16; Top = 200; Width = 390; Height = 34 }))
$ok.Add_Click({
    $picked = GarrysmodIn $gmodBox.Text.Trim().Trim('"')
    if (-not $picked) {
        [void][System.Windows.Forms.MessageBox]::Show($form, "There's no Garry's Mod in that folder. Press Browse and pick the garrysmod folder inside GarrysMod.", 'S3GM setup', 'OK', 'Warning')
        return
    }
    if (-not (Test-Path -LiteralPath $gameBox.Text.Trim().Trim('"') -PathType Leaf)) {
        [void][System.Windows.Forms.MessageBox]::Show($form, 'Pick your Skate 3 disc image (.iso) or default.xex with Browse.', 'S3GM setup', 'OK', 'Warning')
        return
    }
    $gmodBox.Text = $picked
    $form.DialogResult = 'OK'
    $form.Close()
})
$form.Controls.Add($ok); $form.Controls.Add($cancel)
$form.AcceptButton = $ok; $form.CancelButton = $cancel
if ($form.ShowDialog() -ne 'OK') {
    Say 'Setup cancelled, so nothing was installed.'
    exit 0
}
$gmod = $gmodBox.Text
$game = $gameBox.Text.Trim().Trim('"')
$engineArg = if ($engineBox.Checked) { '--audio-engine' } else { '--no-audio-engine' }

# The same window, now showing the progress: a status line, a bar, the log,
# and a Finish button once it's done.
$form.Controls.Clear()
$form.AcceptButton = $null
$form.CancelButton = $null
$form.AutoScroll = $false
$form.FormBorderStyle = 'Sizable'
$form.MaximizeBox = $true
$form.MinimizeBox = $true
$form.Size = New-Object System.Drawing.Size(760, 540)
$form.MinimumSize = New-Object System.Drawing.Size(560, 380)
$logBox = New-Object System.Windows.Forms.TextBox -Property @{
    Multiline = $true; ReadOnly = $true; ScrollBars = 'Vertical'; Dock = 'Fill'; WordWrap = $true
    Font = New-Object System.Drawing.Font('Consolas', 9); BackColor = [System.Drawing.SystemColors]::Window }
$bottom = New-Object System.Windows.Forms.Panel -Property @{ Dock = 'Bottom'; Height = 50 }
$finish = New-Object System.Windows.Forms.Button -Property @{ Text = 'Finish'; Width = 100; Height = 30; Top = 10; Visible = $false; Anchor = 'Top, Right' }
$bottom.Controls.Add($finish)
$finish.Left = $bottom.ClientSize.Width - $finish.Width - 16
$finish.Add_Click({ $form.Close() })
$bar = New-Object System.Windows.Forms.ProgressBar -Property @{ Dock = 'Top'; Height = 18; Style = 'Marquee'; MarqueeAnimationSpeed = 30 }
$status = New-Object System.Windows.Forms.Label -Property @{
    Dock = 'Top'; Height = 96; Padding = New-Object System.Windows.Forms.Padding(4, 8, 4, 4)
    Font = New-Object System.Drawing.Font('Segoe UI', 10); Text = 'Installing S3GM. The first time takes a few minutes.' }
$spacer = New-Object System.Windows.Forms.Panel -Property @{ Dock = 'Top'; Height = 10 }
# Docked controls stack from the last one added, so the log goes in first.
$form.Padding = New-Object System.Windows.Forms.Padding(14, 6, 14, 0)
$form.Controls.Add($logBox)
$form.Controls.Add($spacer)
$form.Controls.Add($bar)
$form.Controls.Add($status)
$form.Controls.Add($bottom)
$form.Add_FormClosing({
    param($sender, $e)
    if (-not $script:installing) { return }
    $answer = [System.Windows.Forms.MessageBox]::Show($form, 'Setup is still installing. Stop it now? You can run it again later.', 'S3GM setup', 'YesNo', 'Warning')
    if ($answer -eq 'Yes') {
        try { if ($script:running) { $script:running.Kill() } } catch {}
        [Environment]::Exit(1)
    }
    $e.Cancel = $true
})
$installing = $true
$form.Show()
$form.Activate()
Pump
Say "Garry's Mod: $gmod"
Say "Skate 3: $game"

# A Python that numpy 2.2 has wheels for: 3.10 to 3.13.
$python = $null
foreach ($candidate in @(@('py', '-3.13'), @('py', '-3.12'), @('py', '-3.11'), @('py', '-3.10'), @('python'))) {
    # Not $rest: that holds the player's own arguments for skate3_setup.py.
    $exe = $candidate[0]; $flags = @($candidate | Select-Object -Skip 1)
    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { continue }
    $pyVersion = Ask $exe ($flags + @('-c', 'import sys; print(sys.version_info[0], sys.version_info[1], sep=chr(46))'))
    # One that can't even start the setup's own imports is as good as none.
    if ($pyVersion -in @('3.10', '3.11', '3.12', '3.13') -and (PythonWorks $exe $flags)) { $python = $candidate; break }
}
if (-not $python) {
    # None installed: Python's own portable build, kept with the rest.
    $portable = Join-Path $cache "python-$PythonVersion"
    $portableExe = Join-Path $portable 'tools\python.exe'
    # A copy that is there but can't start (its Lib folder emptied by a stopped
    # run, an antivirus or a cleaner) is thrown away and fetched again, never reused.
    if (-not (PythonWorks $portableExe @())) { FetchPython }
    $python = @($portableExe)
}
$pyExe = $python[0]; $pyArgs = @($python | Select-Object -Skip 1)

$engine = Join-Path $cache ('engine-' + $EngineRev.Substring(0, 7))
$converters = Join-Path $engine 'tools\asset_pipeline'
if (-not (Test-Path -LiteralPath $converters)) {
    Step "Fetching the Skate 3 engine's converters ($($EngineRev.Substring(0, 7)), one time)..."
    $zip = Join-Path $cache 'engine.zip'
    $partial = "$engine.partial"
    # What a run that stopped part way left behind: a folder already there
    # would swallow the new copy one level down, and the converters would
    # never be found.
    foreach ($old in @($engine, $partial)) {
        if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Recurse -Force }
    }
    try { Download $EngineZip $zip }
    catch { Die "Downloading the Skate 3 engine's converters from github.com failed: $($_.Exception.Message) Check the internet connection, then run this again." }
    try { Unzip $zip $partial }
    catch { Die "Unpacking the Skate 3 engine's converters failed: $($_.Exception.Message) An antivirus may have blocked it: allow the folder $cache, then run this again." }
    Remove-Item -LiteralPath $zip -Force
    # GitHub puts everything in one folder named after the repo and revision.
    $inner = Get-ChildItem -LiteralPath $partial -Directory | Select-Object -First 1
    if (-not $inner) { Die "The Skate 3 engine's converters came down empty. Run this again; if it keeps happening, an antivirus may be emptying $cache." }
    Move-Item -LiteralPath $inner.FullName -Destination $engine
    Remove-Item -LiteralPath $partial -Recurse -Force
    if (-not (Test-Path -LiteralPath $converters)) {
        Die "The Skate 3 engine's converters were fetched, but $converters is missing. An antivirus may have removed it: allow the folder $cache, delete it, then run this again."
    }
}

$vgmDir = Join-Path $cache 'vgmstream'
$vgmstream = Join-Path $vgmDir 'vgmstream-cli.exe'
if (-not (Test-Path $vgmstream)) {
    Step "Fetching vgmstream, which decodes the disc's sounds (one time)..."
    New-Item -ItemType Directory -Force -Path $vgmDir | Out-Null
    $zip = Join-Path $vgmDir 'vgmstream.zip'
    try { Download $VgmstreamZip $zip }
    catch { Die "Downloading vgmstream from github.com failed: $($_.Exception.Message) Check the internet connection, then run this again." }
    try { Unzip $zip $vgmDir }
    catch { Die "Unpacking vgmstream failed: $($_.Exception.Message) An antivirus may have blocked it: allow the folder $cache, then run this again." }
    Remove-Item -Force $zip
}

$venv = Join-Path $cache 'venv'
$venvPython = Join-Path $venv 'Scripts\python.exe'
$ready = $false
if (Test-Path $venvPython) {
    $ready = ($null -ne (Ask $venvPython @('-c', 'import numpy, PIL; print(1)')))
}
if (-not $ready) {
    Step 'Creating a Python environment for the converters (one time)...'
    $venvLog = ''
    $venvCode = 1
    # Twice at most: with our own portable Python, the second try starts from a fresh copy of it.
    for ($attempt = 1; $attempt -le 2 -and $venvCode -ne 0; $attempt++) {
        if ($attempt -eq 2) {
            if (-not $portable) { break }
            Say 'Python could not make its environment; fetching a fresh copy of it and trying once more...'
            FetchPython
        }
        if (Test-Path $venv) { Remove-Item -Recurse -Force $venv }
        $venvCode = Run $pyExe ($pyArgs + @('-I', '-m', 'venv', $venv))
        $venvLog = ($runOutput -join "`n")
    }
    if ($venvCode -ne 0) {
        $tail = if ($venvLog.Length -gt 500) { $venvLog.Substring($venvLog.Length - 500) } else { $venvLog }
        Die ("Python could not make its environment. If an antivirus is running, allow the folder $cache, delete it, then run this again.`n`n" + $tail.Trim())
    }
    [void](Run $venvPython @('-m', 'pip', 'install', '-q', '--upgrade', 'pip'))
    if ((Run $venvPython @('-m', 'pip', 'install', '-q', 'numpy==2.2.6', 'Pillow==11.3.0')) -ne 0) {
        Die 'Installing numpy and Pillow failed (the log above says why).'
    }
}

$env:SKATE3_ENGINE = $engine
$env:SKATE3_VGMSTREAM = $vgmstream
$setup = Join-Path $here 'skate3_setup.py'
Step 'Installing S3GM and converting what it needs from your disc. The first time takes a few minutes.'
$code = Run $venvPython (@($setup, '--game', $game, '--gmod', $gmod, $engineArg) + @($rest))
$tries = 0
while ($code -eq 2 -and $tries -lt 3) {
    # Garry's Mod wasn't found in any Steam library on any drive, or the picked folder had no Gmod in it.
    $tries++
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Garry''s Mod wasn''t found. Select its garrysmod folder (Steam > Garry''s Mod > Manage > Browse local files, then the garrysmod folder inside). The GarrysMod folder or your Steam library folder works too.'
    if ($dialog.ShowDialog($form) -ne 'OK') { Die 'No garrysmod folder picked, so nothing was installed.' }
    $gmod = $dialog.SelectedPath
    $code = Run $venvPython (@($setup, '--game', $game, '--gmod', $gmod, $engineArg) + @($rest))
}
if ($code -ne 0) { Die 'Setup stopped with an error; the log above says why.' }
$done = ("All set! S3GM $version is installed." -replace '  ', ' ') + " Start Garry's Mod, load a map and equip the Skateboard (spawn menu > Weapons > Skate 3)."
# What setup skipped ("Installed, but not everything worked:" and a " - " line each).
$problems = @()
$listing = $false
foreach ($line in $runOutput) {
    if ($line -like 'Installed, but not everything worked*') { $listing = $true; continue }
    if ($listing -and $line -like ' - *') { $problems += $line.Substring(3) }
}
if ($problems) { $done += "`n`nInstalled, but not everything worked:`n- " + ($problems -join "`n- ") }
# A Workshop S3GM of another version loaded alongside can mix with this one.
$steamapps = Split-Path (Split-Path (Split-Path $gmod -Parent) -Parent) -Parent
if (Test-Path -LiteralPath (Join-Path $steamapps 'workshop\content\4000\3814357793')) {
    $done += "`n`nYou're also subscribed to S3GM on the Steam Workshop. That's fine while it's the same version; if the game seems older than this, unsubscribe from it: steamcommunity.com/sharedfiles/filedetails/?id=3814357793"
}
Say ''
Say $done
$installing = $false
$bar.Style = 'Continuous'
$bar.Value = 100
$status.Height = if ($problems -or $done.Length -gt 200) { 170 } else { 70 }
$status.ForeColor = if ($problems) { [System.Drawing.Color]::DarkOrange } else { [System.Drawing.Color]::DarkGreen }
$status.Text = $done
$finish.Visible = $true
$form.AcceptButton = $finish
# Pops up over whatever the player switched to while it ran, then stays a normal window.
$form.WindowState = 'Normal'
$form.TopMost = $true
$form.Activate()
$form.TopMost = $false
[void]$finish.Focus()
while ($form.Visible) { Pump }
exit 0
