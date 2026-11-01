# deploy.ps1
# Local deployment of FS25_FarmTaskBoard:
#   1. builds dist\FS25_FarmTaskBoard.zip from Build\ (the contents, not the folder)
#   2. hard-kills Farming Simulator 25 if it is running
#   3. saves the last log.txt to dist\logs\ (a new start overwrites it)
#   4. copies the zip to the mods folder
#   5. starts the game again through Steam
#
# Usage (from anywhere):
#   pwsh -File tools\deploy.ps1            build, kill, copy, start
#   pwsh -File tools\deploy.ps1 -NoStart   build, kill, copy; do not start the game

param(
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'

$ModName      = 'FS25_FarmTaskBoard'
$SteamAppId   = 2300320   # Farming Simulator 25 on Steam
$RepoRoot     = Split-Path -Parent $PSScriptRoot
$SourceDir    = Join-Path $RepoRoot 'Build'
$DistDir      = Join-Path $RepoRoot 'dist'
$ZipPath      = Join-Path $DistDir "$ModName.zip"
# Documents may be redirected (OneDrive), so ask Windows instead of using $HOME\Documents
$GameUserDir  = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'My Games\FarmingSimulator2025'
$ModsDir      = Join-Path $GameUserDir 'mods'
$LogFile      = Join-Path $GameUserDir 'log.txt'

# --- 1. Build -------------------------------------------------------------
if (-not (Test-Path (Join-Path $SourceDir 'modDesc.xml'))) {
    throw "modDesc.xml not found in $SourceDir"
}
New-Item -ItemType Directory -Force $DistDir | Out-Null
if (Test-Path $ZipPath) { Remove-Item $ZipPath }

Add-Type -AssemblyName System.IO.Compression.FileSystem
$sourceFull = (Resolve-Path $SourceDir).Path
$zip = [IO.Compression.ZipFile]::Open($ZipPath, 'Create')
try {
    Get-ChildItem $sourceFull -Recurse -File | ForEach-Object {
        # Forward slashes: the game does not find files stored with backslashes
        $entry = $_.FullName.Substring($sourceFull.Length + 1).Replace('\', '/')
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $_.FullName, $entry)
    }
} finally {
    $zip.Dispose()
}
$version = ([xml](Get-Content (Join-Path $SourceDir 'modDesc.xml') -Raw)).modDesc.version
Write-Host "Built $ZipPath (version $version)"

# --- 2. Kill the game -----------------------------------------------------
# FarmingSimulator2025.exe (launcher) and FarmingSimulator2025Game.exe (the game)
$game = Get-Process -Name 'FarmingSimulator2025*' -ErrorAction SilentlyContinue
if ($game) {
    Write-Host "Killing: $(($game | ForEach-Object { "$($_.Name) ($($_.Id))" }) -join ', ')"
    $game | Stop-Process -Force
    # Wait until the processes are gone, so the zip in the mods folder is no longer locked
    $game | Wait-Process -Timeout 30 -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
} else {
    Write-Host 'Game not running'
}

# --- 3. Keep the last log -------------------------------------------------
if (Test-Path $LogFile) {
    $logDir = Join-Path $DistDir 'logs'
    New-Item -ItemType Directory -Force $logDir | Out-Null
    $stamp = (Get-Item $LogFile).LastWriteTime.ToString('yyyy-MM-dd_HHmmss')
    $saved = Join-Path $logDir "log_$stamp.txt"
    Copy-Item $LogFile $saved -Force
    Write-Host "Saved last log to $saved"
    $hits = Select-String -Path $saved -Pattern 'FarmTaskBoard' -SimpleMatch
    if ($hits) {
        Write-Host "Lines with FarmTaskBoard in that log:"
        $hits | Select-Object -Last 20 | ForEach-Object { Write-Host "  $($_.Line)" }
    }
}

# --- 4. Copy to the mods folder -------------------------------------------
if (-not (Test-Path $ModsDir)) {
    throw "Mods folder not found: $ModsDir"
}
# An unzipped copy with the same name would win over the zip or clash with it
$unzipped = Join-Path $ModsDir $ModName
if (Test-Path $unzipped) {
    Write-Warning "Unzipped mod folder $unzipped exists and may be loaded instead of the zip"
}
Copy-Item $ZipPath (Join-Path $ModsDir "$ModName.zip") -Force
Write-Host "Copied to $ModsDir"

# --- 5. Start the game ----------------------------------------------------
if ($NoStart) {
    Write-Host 'Not starting the game (-NoStart)'
} else {
    Write-Host 'Starting Farming Simulator 25 through Steam'
    Start-Process "steam://rungameid/$SteamAppId"
}
