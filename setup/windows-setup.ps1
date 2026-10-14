# S3GM (Skate 3 in Garry's Mod) setup for Windows. The Windows twin of
# skate3-setup.sh; S3GM-setup-Windows.bat starts it.
#
#   drag your Skate 3 .iso onto S3GM-setup-Windows.bat     no questions asked
#   double-click S3GM-setup-Windows.bat                    uses an .iso beside
#                                                          it, or asks for one
#   S3GM-setup-Windows.bat --game "D:\Skate 3\skate3.iso"  [--gmod <folder>]
#
# The Lua addon comes from the Steam Workshop; this installs the skate module
# and converts what it needs from the disc. Nothing needs installing first:
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
$cache = Join-Path $env:LOCALAPPDATA 'skate3-gmod'
New-Item -ItemType Directory -Force -Path $cache | Out-Null

Add-Type -AssemblyName System.Windows.Forms
function Die($message) {
    Write-Host "error: $message" -ForegroundColor Red
    [void][System.Windows.Forms.MessageBox]::Show($message, 'S3GM setup', 'OK', 'Error')
    exit 1
}

# What to convert: a disc image dragged onto the .bat, --game, an .iso (or
# extracted default.xex) sitting beside the setup, or one picked in a window.
$rest = @()
$game = $null
for ($i = 0; $i -lt $args.Count; $i++) {
    if ($args[$i] -eq '--game' -and $i + 1 -lt $args.Count) { $game = $args[$i + 1]; $i++ }
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
    if ($beside.Count -eq 1) { $game = $beside[0].FullName; Write-Host "Using $game" }
}
if (-not $game) {
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = 'Select your Skate 3 (Xbox 360) disc image, or default.xex'
    $dialog.Filter = 'Skate 3 disc image (*.iso;default.xex)|*.iso;default.xex|All files (*.*)|*.*'
    if ($dialog.ShowDialog() -ne 'OK') { Die 'No Skate 3 disc picked, so nothing was installed.' }
    $game = $dialog.FileName
}

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
& $venvPython $setup --game $game @rest
if ($LASTEXITCODE -eq 2) {
    # Garry's Mod wasn't found in any Steam library.
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Garry''s Mod wasn''t found. Select its garrysmod folder (Steam > Garry''s Mod > Manage > Browse local files, then the garrysmod folder inside).'
    if ($dialog.ShowDialog() -ne 'OK') { Die 'No garrysmod folder picked, so nothing was installed.' }
    & $venvPython $setup --game $game --gmod $dialog.SelectedPath @rest
}
if ($LASTEXITCODE -ne 0) { Die 'Setup stopped with an error; the window above says why.' }
[void][System.Windows.Forms.MessageBox]::Show("All set! Subscribe to S3GM on the Steam Workshop if you haven't, then start Garry's Mod, load a map and equip the Skateboard.", 'S3GM setup')
exit 0
