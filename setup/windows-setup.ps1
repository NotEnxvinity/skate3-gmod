# S3GM (Skate 3 in Garry's Mod) setup for Windows. The Windows twin of
# skate3-setup.sh; S3GM-setup-Windows.bat starts it.
#
#   drag your Skate 3 .iso onto S3GM-setup-Windows.bat     fills in the disc
#   double-click S3GM-setup-Windows.bat                    finds an .iso beside
#                                                          it, if there is one
#   S3GM-setup-Windows.bat --game "D:\Skate 3\skate3.iso"  [--gmod <folder>]
#
# Either way a small window shows the Garry's Mod folder and disc it found,
# so the player checks or changes them before anything runs.
#
# This installs the S3GM addon and skate module into Garry's Mod and converts
# what it needs from the disc. Nothing needs installing first:
# without a Python 3.10 to 3.13 on the computer, the first run downloads
# Python's own portable build (the "python" package Python publishes on
# NuGet) into %LOCALAPPDATA%\skate3-gmod, along with the Skate 3 engine's
# converters, vgmstream, and numpy and Pillow in a private environment.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

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

# The engine revision the skate host was built from (the same as skate3-setup.sh).
$EngineRev = 'cb7968930f14dad38457e98720d1a274e469eec2'
# Python's portable Windows build, published by Python itself on NuGet.
$PythonVersion = '3.13.16'
$PythonZip = "https://api.nuget.org/v3-flatcontainer/python/$PythonVersion/python.$PythonVersion.nupkg"
$EngineZip = "https://github.com/SK8-ENGINE/skate-3-rust-engine/archive/$EngineRev.zip"
$VgmstreamZip = 'https://github.com/vgmstream/vgmstream-releases/releases/download/nightly/vgmstream-win64.zip'

$here = $PSScriptRoot
# The S3GM version this setup installs, shown in its windows.
$version = ''
try { $version = (Get-Content -LiteralPath (Join-Path $here 'VERSION') -Raw -ErrorAction Stop).Trim() } catch {}
$cache = Join-Path $env:LOCALAPPDATA 'skate3-gmod'
New-Item -ItemType Directory -Force -Path $cache | Out-Null

Add-Type -AssemblyName System.Windows.Forms
function Die($message) {
    Write-Host "error: $message" -ForegroundColor Red
    [void][System.Windows.Forms.MessageBox]::Show($message, 'S3GM setup', 'OK', 'Error')
    exit 1
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
    $parent = Split-Path $here -Parent
    $beside = @(Get-ChildItem -LiteralPath $here, $parent -File -ErrorAction SilentlyContinue |
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
    Text = ("S3GM $version setup" -replace '  ', ' '); Width = 640; Height = 270; FormBorderStyle = 'FixedDialog'; MaximizeBox = $false
    MinimizeBox = $false; StartPosition = 'CenterScreen'; TopMost = $true
}
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
$ok = New-Object System.Windows.Forms.Button -Property @{ Text = 'Install'; Left = 420; Top = 150; Width = 90; Height = 30 }
$cancel = New-Object System.Windows.Forms.Button -Property @{ Text = 'Cancel'; Left = 516; Top = 150; Width = 90; Height = 30; DialogResult = 'Cancel' }
$form.Controls.Add((New-Object System.Windows.Forms.Label -Property @{
    Text = 'Check both, then press Install.'; Left = 16; Top = 156; Width = 380; Height = 20 }))
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
if ($form.ShowDialog() -ne 'OK') { Die 'Setup cancelled, so nothing was installed.' }
$gmod = $gmodBox.Text
$game = $gameBox.Text.Trim().Trim('"')
$form.Dispose()
Write-Host "Garry's Mod: $gmod"
Write-Host "Skate 3: $game"

# A Python that numpy 2.2 has wheels for: 3.10 to 3.13.
$python = $null
foreach ($candidate in @(@('py', '-3.13'), @('py', '-3.12'), @('py', '-3.11'), @('py', '-3.10'), @('python'))) {
    # Not $rest: that holds the player's own arguments for skate3_setup.py.
    $exe = $candidate[0]; $flags = @($candidate | Select-Object -Skip 1)
    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { continue }
    $version = Ask $exe ($flags + @('-c', 'import sys; print(sys.version_info[0], sys.version_info[1], sep=chr(46))'))
    if ($version -in @('3.10', '3.11', '3.12', '3.13')) { $python = $candidate; break }
}
if (-not $python) {
    # None installed: Python's own portable build, kept with the rest.
    $portable = Join-Path $cache "python-$PythonVersion"
    $portableExe = Join-Path $portable 'tools\python.exe'
    if (-not (Test-Path $portableExe)) {
        Write-Host "Fetching Python $PythonVersion for the converters (one time, nothing is installed)..."
        $zip = Join-Path $cache 'python.zip'
        $partial = "$portable.partial"
        # A copy a stopped run left half done would swallow the new one.
        foreach ($old in @($portable, $partial)) {
            if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Recurse -Force }
        }
        try { Invoke-WebRequest -Uri $PythonZip -OutFile $zip -UseBasicParsing }
        catch { Die "Downloading Python from nuget.org failed: $($_.Exception.Message) Check the internet connection, then run this again." }
        try { Expand-Archive -LiteralPath $zip -DestinationPath $partial -Force }
        catch { Die "Unpacking Python failed: $($_.Exception.Message) An antivirus may have blocked it: allow the folder $cache, then run this again." }
        Remove-Item -LiteralPath $zip -Force
        Move-Item -LiteralPath $partial -Destination $portable
        if (-not (Test-Path -LiteralPath $portableExe)) {
            Die "Python was fetched, but $portableExe is missing. An antivirus may have removed it: allow the folder $cache, delete it, then run this again."
        }
    }
    $python = @($portableExe)
}
$pyExe = $python[0]; $pyArgs = @($python | Select-Object -Skip 1)

$engine = Join-Path $cache ('engine-' + $EngineRev.Substring(0, 7))
$converters = Join-Path $engine 'tools\asset_pipeline'
if (-not (Test-Path -LiteralPath $converters)) {
    Write-Host "Fetching the Skate 3 engine's converters ($($EngineRev.Substring(0, 7)), one time)..."
    $zip = Join-Path $cache 'engine.zip'
    $partial = "$engine.partial"
    # What a run that stopped part way left behind: a folder already there
    # would swallow the new copy one level down, and the converters would
    # never be found.
    foreach ($old in @($engine, $partial)) {
        if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Recurse -Force }
    }
    try { Invoke-WebRequest -Uri $EngineZip -OutFile $zip -UseBasicParsing }
    catch { Die "Downloading the Skate 3 engine's converters from github.com failed: $($_.Exception.Message) Check the internet connection, then run this again." }
    try { Expand-Archive -LiteralPath $zip -DestinationPath $partial -Force }
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
    Write-Host "Fetching vgmstream, which decodes the disc's sounds (one time)..."
    New-Item -ItemType Directory -Force -Path $vgmDir | Out-Null
    $zip = Join-Path $vgmDir 'vgmstream.zip'
    Invoke-WebRequest -Uri $VgmstreamZip -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $vgmDir -Force
    Remove-Item -Force $zip
}

$venv = Join-Path $cache 'venv'
$venvPython = Join-Path $venv 'Scripts\python.exe'
$ready = $false
if (Test-Path $venvPython) {
    $ready = ($null -ne (Ask $venvPython @('-c', 'import numpy, PIL; print(1)')))
}
if (-not $ready) {
    Write-Host 'Creating a Python environment for the converters (one time)...'
    if (Test-Path $venv) { Remove-Item -Recurse -Force $venv }
    & $pyExe @pyArgs -m venv $venv
    if ($LASTEXITCODE -ne 0) { Die 'Python could not make its environment.' }
    & $venvPython -m pip install -q --upgrade pip
    & $venvPython -m pip install -q 'numpy==2.2.6' 'Pillow==11.3.0'
    if ($LASTEXITCODE -ne 0) { Die 'Installing numpy and Pillow failed (see above).' }
}

$env:SKATE3_ENGINE = $engine
$env:SKATE3_VGMSTREAM = $vgmstream
$setup = Join-Path $here 'skate3_setup.py'
& $venvPython $setup --game $game --gmod $gmod @rest
$tries = 0
while ($LASTEXITCODE -eq 2 -and $tries -lt 3) {
    # Garry's Mod wasn't found in any Steam library on any drive, or the picked folder had no Gmod in it.
    $tries++
    $owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true }
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Garry''s Mod wasn''t found. Select its garrysmod folder (Steam > Garry''s Mod > Manage > Browse local files, then the garrysmod folder inside). The GarrysMod folder or your Steam library folder works too.'
    $picked = $dialog.ShowDialog($owner)
    $owner.Dispose()
    if ($picked -ne 'OK') { Die 'No garrysmod folder picked, so nothing was installed.' }
    & $venvPython $setup --game $game --gmod $dialog.SelectedPath @rest
}
if ($LASTEXITCODE -ne 0) { Die 'Setup stopped with an error; the window above says why.' }
$done = ("All set! S3GM $version is installed." -replace '  ', ' ') + "`n`nStart Garry's Mod, load a map and equip the Skateboard (spawn menu > Weapons > Skate 3)."
# The Workshop S3GM is an older version; both loaded at once can mix.
$steamapps = Split-Path (Split-Path (Split-Path $gmod -Parent) -Parent) -Parent
if (Test-Path -LiteralPath (Join-Path $steamapps 'workshop\content\4000\3814357793')) {
    $done += "`n`nYou're also subscribed to S3GM on the Steam Workshop, which is an older version. Unsubscribe from it while testing, so the two can't mix: steamcommunity.com/sharedfiles/filedetails/?id=3814357793"
}
[void][System.Windows.Forms.MessageBox]::Show($done, 'S3GM setup')
exit 0
