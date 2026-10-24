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
$installerPath = Join-Path $env:TEMP $fileName

Step "Downloading SuperSQE v$Version"
Write-Host "    $url"
try {
  Invoke-WebRequest -Uri $url -OutFile $installerPath -UseBasicParsing
} catch {
  FailMsg "Download failed: $($_.Exception.Message)`nCheck that v$Version exists at github.com/supersqe/installers/releases"
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

# ---- Install -------------------------------------------------------------
Step "Installing - port $Port, administrator $AdminEmail"
$installArgs = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/Port=$Port", "/AdminEmail=$AdminEmail")
$proc = Start-Process -FilePath $installerPath -ArgumentList $installArgs -Wait -PassThru
if ($proc.ExitCode -ne 0) { FailMsg "The installer exited with code $($proc.ExitCode). Check the installer log in %TEMP%." }
OkMsg 'Installer finished.'

# ---- Wait for first boot + Welcome Pack ----------------------------------
$dataDir = Join-Path $env:ProgramFiles 'SuperSQE\data'
$welcome = Join-Path $dataDir 'welcome.txt'
$creds = Join-Path $dataDir 'admin-credentials.txt'
$healthUrl = "http://127.0.0.1:$Port/api/health"

Step 'Waiting for the first boot (database + schema) - this can take a few minutes'
$ready = $false
for ($i = 0; $i -lt 150; $i++) {
  if (Test-Path $welcome) { $ready = $true; break }
  try {
    $resp = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
    if ($resp.StatusCode -eq 200) { $ready = $true; break }
  } catch { }
  Start-Sleep -Seconds 2
}
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
