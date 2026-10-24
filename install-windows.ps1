<#
.SYNOPSIS
  SuperSQE interactive command-line installer for Windows.

.DESCRIPTION
  Mirrors the executable installer experience from a terminal:
    1. prompts for the web port (default 3000) and the administrator email (required),
    2. downloads the latest signed installer from the public release repository,
    3. verifies the Authenticode signature,
    4. installs silently with the chosen port + admin email,
    5. waits for first boot and prints the Welcome Pack (admin login + details).

  Run it from an elevated PowerShell (or it will relaunch itself elevated).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\install-windows.ps1

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\install-windows.ps1 -Port 8443 -AdminEmail you@company.com
#>
[CmdletBinding()]
param(
  [int]$Port = 0,
  [string]$AdminEmail = '',
  [string]$Version = '1.0.5',
  [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function OkMsg($msg) { Write-Host "    $msg" -ForegroundColor Green }
function WarnMsg($msg) { Write-Host "    $msg" -ForegroundColor Yellow }
function FailMsg($msg) { Write-Host "`nERROR: $msg" -ForegroundColor Red; exit 1 }

# ---- Administrator check (relaunch elevated if needed) --------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  WarnMsg 'Administrator rights are required - relaunching elevated...'
  $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Version', $Version)
  if ($Port -gt 0) { $argList += @('-Port', "$Port") }
  if ($AdminEmail) { $argList += @('-AdminEmail', $AdminEmail) }
  Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs
  exit
}

# ---- Port ----------------------------------------------------------------
if ($Port -eq 0) {
  $entered = Read-Host 'Web port [3000]'
  if ([string]::IsNullOrWhiteSpace($entered)) { $Port = 3000 } else { $Port = [int]$entered }
}
if ($Port -lt 1 -or $Port -gt 65535) { FailMsg "Invalid port '$Port' - use a number between 1 and 65535." }

$portInUse = $false
try {
  $listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
  if ($listener) { $portInUse = $true }
} catch { }
if ($portInUse -and -not $Force) {
  WarnMsg "Port $Port is already in use by another program."
  $answer = Read-Host 'Continue anyway? (y/N)'
  if ($answer -notmatch '^(y|yes)$') { FailMsg 'Installation cancelled. Choose a free port and run again.' }
}

# ---- Administrator email (required) --------------------------------------
if (-not $AdminEmail) {
  while ($true) {
    $AdminEmail = (Read-Host 'Administrator email (required - this is your SuperSQE login)').Trim()
    if ($AdminEmail -match '^[^@\s]+@[^@\s]+\.[^@\s]+$') { break }
    WarnMsg 'Enter a valid email address, for example name@company.com'
    $AdminEmail = ''
  }
}
if ($AdminEmail -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { FailMsg "Invalid admin email '$AdminEmail'." }

# ---- Download ------------------------------------------------------------
$fileName = "supersqe-setup-$Version-x64.exe"
$url = "https://github.com/supersqe/installers/releases/download/v$Version/$fileName"

# A previous silent install may still be running and locking the exe in %TEMP%.
$prior = Get-Process -Name 'supersqe-setup*' -ErrorAction SilentlyContinue
if ($prior) {
  WarnMsg "A previous SuperSQE installer is still running (PID $($prior.Id -join ',')) - waiting for it to finish..."
  while ($prior -and -not $prior.HasExited) {
    Start-Sleep -Seconds 2
    $prior.Refresh()
  }
  OkMsg 'Previous installer finished.'
}

$downloadDir = Join-Path $env:LOCALAPPDATA 'SuperSQE\downloads'
New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null
$installerPath = Join-Path $downloadDir $fileName
if (Test-Path $installerPath) { Remove-Item $installerPath -Force -ErrorAction SilentlyContinue }
if (Test-Path $installerPath) {
  # Still locked (e.g. by a virus scanner) - use a unique name for this run.
  $installerPath = Join-Path $downloadDir ("supersqe-setup-$Version-x64-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".exe")
}

Step "Downloading SuperSQE v$Version"
Write-Host "    $url"
Write-Host "    -> $installerPath"
try {
  $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
  if ($curl) {
    & $curl.Source -fL --progress-bar --retry 3 --retry-delay 2 -o $installerPath $url
    if ($LASTEXITCODE -ne 0) { throw "curl exited with $LASTEXITCODE" }
  } else {
    $ProgressPreference = 'Continue'
    Invoke-WebRequest -Uri $url -OutFile $installerPath -UseBasicParsing
  }
} catch {
  FailMsg "Download failed: $($_.Exception.Message)`nCheck that v$Version exists at github.com/supersqe/installers/releases`nIf a previous installer is still running, close it (Task Manager) and run again."
}
OkMsg $installerPath

# ---- Verify the signature ------------------------------------------------
Step 'Verifying the digital signature'
$sig = Get-AuthenticodeSignature $installerPath
if ($sig.Status -ne 'Valid') {
  FailMsg "The installer signature is not valid ($($sig.Status)). Download it from https://www.supersqe.com/downloads and try again."
}
OkMsg "Valid signature - publisher: $($sig.SignerCertificate.Subject)"
if ($sig.TimeStamperCertificate) { OkMsg "Timestamped by: $($sig.TimeStamperCertificate.Subject)" }

# ---- Install (with live progress) ----------------------------------------
Step "Installing - port $Port, administrator $AdminEmail"
$installerLog = Join-Path $env:TEMP "supersqe-installer-$Version.log"
$installArgs = @(
  '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART',
  "/LOG=$installerLog", "/Port=$Port", "/AdminEmail=$AdminEmail"
)
$dataDir = Join-Path $env:ProgramFiles 'SuperSQE\data'
$svcLog = Join-Path $dataDir 'service-install.log'

$proc = Start-Process -FilePath $installerPath -ArgumentList $installArgs -PassThru
$started = Get-Date
$lastStatus = ''
$lastBeat = 0
while (-not $proc.HasExited) {
  $elapsed = [int]((Get-Date) - $started).TotalSeconds
  $pct = [Math]::Min(30, 5 + [int]($elapsed / 2))
  $phase = 'Installing files'

  if (Test-Path $svcLog) {
    $line = Get-Content $svcLog -Tail 1 -ErrorAction SilentlyContinue
    if ($line) {
      $lastStatus = $line.Trim()
      switch -Regex ($lastStatus.ToLower()) {
        'complete'                        { $pct = 88; $phase = 'Finishing services' }
        'starting (the )?service|healthy' { $pct = 82; $phase = 'Starting services' }
        'schema|db push|migrat'           { $pct = 72; $phase = 'Applying database schema' }
        'postgres|database|initdb'        { $pct = 55; $phase = 'Initialising database' }
        'config|password|admin'           { $pct = 35; $phase = 'Writing configuration' }
        default                           { $pct = 45; $phase = 'Configuring' }
      }
    }
  }

  Write-Progress -Activity 'SuperSQE installation' -Status "$phase - ${elapsed}s" `
    -PercentComplete $pct -CurrentOperation $lastStatus
  if ($elapsed - $lastBeat -ge 30) {
    $lastBeat = $elapsed
    WarnMsg "still installing... ${elapsed}s ($phase)"
  }
  Start-Sleep -Milliseconds 700
}
$proc.WaitForExit()
Write-Progress -Activity 'SuperSQE installation' -Completed
if ($proc.ExitCode -ne 0) {
  FailMsg "The installer exited with code $($proc.ExitCode). See $installerLog and $svcLog"
}
OkMsg 'Installer finished.'

# ---- Wait for first boot + Welcome Pack (progress 90-100%) ----------------
$welcome = Join-Path $dataDir 'welcome.txt'
$creds = Join-Path $dataDir 'admin-credentials.txt'
$healthUrl = "http://127.0.0.1:$Port/api/health"

Step 'Waiting for the first boot (database + schema) - this can take a few minutes'
$bootStart = Get-Date
$ready = $false
$lastBootBeat = 0
for ($i = 0; $i -lt 150; $i++) {
  $elapsed = [int]((Get-Date) - $bootStart).TotalSeconds
  $pct = [Math]::Min(99, 90 + [int]($elapsed / 5))
  Write-Progress -Activity 'SuperSQE first boot' -Status "starting the server - ${elapsed}s" -PercentComplete $pct

  if (Test-Path $welcome) { $ready = $true; break }
  try {
    $resp = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
    if ($resp.StatusCode -eq 200) { $ready = $true; break }
  } catch { }
  if ($elapsed - $lastBootBeat -ge 30) {
    $lastBootBeat = $elapsed
    WarnMsg "still starting... ${elapsed}s"
  }
  Start-Sleep -Seconds 2
}
Write-Progress -Activity 'SuperSQE first boot' -Completed
if (-not $ready) { WarnMsg 'The server is still starting. It will be ready in a few minutes.' }

# ---- Welcome Pack --------------------------------------------------------
Step 'Installation complete'
Write-Host ""
Write-Host "  SuperSQE is installed and running." -ForegroundColor Green
Write-Host "  URL:      http://localhost:$Port"
Write-Host "  Data dir: $dataDir"
Write-Host ""

$welcomeText = $null
if (Test-Path $welcome) { $welcomeText = Get-Content $welcome -Raw }
elseif (Test-Path $creds) { $welcomeText = Get-Content $creds -Raw }

if ($welcomeText) {
  Write-Host '---------------------------- Welcome Pack ----------------------------' -ForegroundColor Cyan
  Write-Host $welcomeText
  Write-Host '----------------------------------------------------------------------' -ForegroundColor Cyan
} else {
  WarnMsg "Welcome Pack not written yet. Read it shortly at: $welcome"
}

Start-Process "http://localhost:$Port"
