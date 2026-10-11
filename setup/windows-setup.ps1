# S3GM (Skate 3 in Garry's Mod) setup for Windows, run with your own Python.
# The Windows twin of skate3-setup.sh; S3GM-setup-Windows.bat starts it.
#
#   S3GM-setup-Windows.bat                                  the setup window
#   S3GM-setup-Windows.bat --game "D:\Skate 3\skate3.iso"   the same without it
#
# Needs Python 3.10 to 3.13 from python.org. The first run downloads the
# Skate 3 engine's converters and vgmstream into %LOCALAPPDATA%\skate3-gmod,
# and numpy and Pillow into a private Python environment there.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# The engine revision the skate host was built from (the same as skate3-setup.sh).
$EngineRev = 'cb7968930f14dad38457e98720d1a274e469eec2'
$EngineZip = "https://github.com/SK8-ENGINE/skate-3-rust-engine/archive/$EngineRev.zip"
$VgmstreamZip = 'https://github.com/vgmstream/vgmstream-releases/releases/download/nightly/vgmstream-win64.zip'

$here = $PSScriptRoot
$cache = Join-Path $env:LOCALAPPDATA 'skate3-gmod'
New-Item -ItemType Directory -Force -Path $cache | Out-Null

function Die($message) { Write-Host "error: $message" -ForegroundColor Red; exit 1 }

# A Python that numpy 2.2 has wheels for: 3.10 to 3.13.
$python = $null
foreach ($candidate in @(@('py', '-3.13'), @('py', '-3.12'), @('py', '-3.11'), @('py', '-3.10'), @('python'))) {
    $exe = $candidate[0]; $rest = @($candidate | Select-Object -Skip 1)
    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { continue }
    $version = & $exe @rest -c 'import sys; print(sys.version_info[0], sys.version_info[1], sep=chr(46))' 2>$null
    if ($LASTEXITCODE -eq 0 -and $version -in @('3.10', '3.11', '3.12', '3.13')) { $python = $candidate; break }
}
if (-not $python) { Die 'Python 3.10 to 3.13 is needed. Install Python 3.13 from python.org (tick "Add python.exe to PATH"), then run this again.' }
$pyExe = $python[0]; $pyArgs = @($python | Select-Object -Skip 1)

$engine = Join-Path $cache ('engine-' + $EngineRev.Substring(0, 7))
if (-not (Test-Path (Join-Path $engine 'tools\asset_pipeline'))) {
    Write-Host "Fetching the Skate 3 engine's converters ($($EngineRev.Substring(0, 7)), one time)..."
    $zip = Join-Path $cache 'engine.zip'
    $partial = "$engine.partial"
    if (Test-Path $partial) { Remove-Item -Recurse -Force $partial }
    Invoke-WebRequest -Uri $EngineZip -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $partial -Force
    Remove-Item -Force $zip
    # GitHub puts everything in one folder named after the repo and revision.
    $inner = Get-ChildItem -Directory $partial | Select-Object -First 1
    Move-Item $inner.FullName $engine
    Remove-Item -Recurse -Force $partial
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
    & $venvPython -c 'import numpy, PIL' 2>$null
    $ready = ($LASTEXITCODE -eq 0)
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
# --with-addon keeps this build's Lua, as on Linux.
& $venvPython (Join-Path $here 'skate3_setup.py') --with-addon @args
exit $LASTEXITCODE
