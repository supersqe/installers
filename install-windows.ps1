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
  [switch]$Force,
  [switch]$AddDefenderExclusion
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

Write-Host ""
Write-Host "  Note: the installation can take up to 20 minutes depending on your" -ForegroundColor DarkGray
Write-Host "  network speed and PC configuration (the first boot prepares the database)." -ForegroundColor DarkGray
Write-Host ""

# ---- Existing installation? (upgrades keep the port + admin account) ------
$dataDir = Join-Path $env:ProgramFiles 'SuperSQE\data'
$existingCfg = Join-Path $dataDir 'config.env'
$isUpgrade = Test-Path $existingCfg
$existingPort = 0
if ($isUpgrade) {
  try {
    $portLine = Select-String -Path $existingCfg -Pattern '^PORT=(\d+)' -ErrorAction Stop | Select-Object -First 1
    if ($portLine) { $existingPort = [int]$portLine.Matches[0].Groups[1].Value }
  } catch { }
  if ($existingPort -gt 0) { $Port = $existingPort }
  Step "Existing SuperSQE installation detected"
  Write-Host "    Upgrades keep your current configuration: port $existingPort and the existing administrator account."
  Write-Host "    (To change the port later: edit $existingCfg and restart 'SuperSQE Server'.)"
}

# ---- Optional: Defender exclusion (much faster installs) -----------------
try {
  $defender = Get-MpComputerStatus -ErrorAction Stop
  $installRoot = Join-Path $env:ProgramFiles 'SuperSQE'
  $excluded = $false
  try { $excluded = @((Get-MpPreference -ErrorAction Stop).ExclusionPath) -contains $installRoot } catch { }
  if ($defender.RealTimeProtectionEnabled -and -not $excluded) {
    $addExclusion = $AddDefenderExclusion.IsPresent
    if (-not $addExclusion) {
      $ans = Read-Host "Add a Microsoft Defender exclusion for '$installRoot' to speed up the install? (Y/n)"
      $addExclusion = ($ans -notmatch '^(n|no)$')
    }
    if ($addExclusion) {
      Add-MpPreference -ExclusionPath $installRoot -ErrorAction Stop
      OkMsg "Defender exclusion added for $installRoot"
    }
  }
} catch {
  # Defender may be disabled or managed by policy - not fatal.
}

# ---- Port ----------------------------------------------------------------
if (-not $isUpgrade -and $Port -eq 0) {
  $entered = Read-Host 'Web port [3000]'
  if ([string]::IsNullOrWhiteSpace($entered)) { $Port = 3000 } else { $Port = [int]$entered }
}
if ($Port -eq 0) { $Port = 3000 }
if ($Port -lt 1 -or $Port -gt 65535) { FailMsg "Invalid port '$Port' - use a number between 1 and 65535." }

$portInUse = $false
try {
  $listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
  if ($listener) { $portInUse = $true }
} catch { }
if ($portInUse -and -not $isUpgrade -and -not $Force) {
  WarnMsg "Port $Port is already in use by another program."
  $answer = Read-Host 'Continue anyway? (y/N)'
  if ($answer -notmatch '^(y|yes)$') { FailMsg 'Installation cancelled. Choose a free port and run again.' }
}

# ---- Administrator email (required on first install) --------------------
if ($isUpgrade) {
  if (-not $AdminEmail) { $AdminEmail = 'unchanged@supersqe.local' }
} else {
  if (-not $AdminEmail) {
    while ($true) {
      $AdminEmail = (Read-Host 'Administrator email (required - this is your SuperSQE login)').Trim()
      if ($AdminEmail -match '^[^@\s]+@[^@\s]+\.[^@\s]+$') { break }
      WarnMsg 'Enter a valid email address, for example name@company.com'
      $AdminEmail = ''
    }
  }
  if ($AdminEmail -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { FailMsg "Invalid admin email '$AdminEmail'." }
}

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
if ($isUpgrade) { Step "Upgrading SuperSQE on port $Port (administrator account preserved)" }
else { Step "Installing - port $Port, administrator $AdminEmail" }
$installerLog = Join-Path $env:TEMP "supersqe-installer-$Version.log"
# Quote path-like parameters so Inno parses them correctly (TEMP contains spaces).
$installArgs = @(
  '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART',
  "/LOG=`"$installerLog`"", "/Port=$Port", "/AdminEmail=`"$AdminEmail`""
)
$svcLog = Join-Path $dataDir 'service-install.log'

$proc = Start-Process -FilePath $installerPath -ArgumentList $installArgs -PassThru
$started = Get-Date
$lastStatus = ''
$lastBeat = 0
$progressNotes = @(
  'Copying application files and the bundled browser runtime...',
  'Unpacking the bundled PostgreSQL database and runner agents...',
  'Preparing the database and applying the schema (first boot)...',
  'Registering the SuperSQE Windows service...',
  'Starting the server and waiting for the health check...',
  'Still working - installs can take up to 20 minutes on slower PCs...'
)
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
  if ($elapsed - $lastBeat -ge 60) {
    $lastBeat = $elapsed
    $noteIndex = [Math]::Min($progressNotes.Count - 1, [int][Math]::Floor($elapsed / 60) - 1)
    if ($noteIndex -lt 0) { $noteIndex = 0 }
    WarnMsg ("{0} ({1}m {2}s)" -f $progressNotes[$noteIndex], [int]($elapsed / 60), ($elapsed % 60))
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
$bootNotes = @(
  'Initialising the bundled PostgreSQL database...',
  'Applying the database schema (first boot only)...',
  'Creating the administrator account and the Welcome Pack...',
  'Starting the SuperSQE server and verifying health...',
  'Still starting - first boot can take several minutes on slower PCs...'
)
for ($i = 0; $i -lt 150; $i++) {
  $elapsed = [int]((Get-Date) - $bootStart).TotalSeconds
  $pct = [Math]::Min(99, 90 + [int]($elapsed / 5))
  Write-Progress -Activity 'SuperSQE first boot' -Status "starting the server - ${elapsed}s" -PercentComplete $pct

  if (Test-Path $welcome) { $ready = $true; break }
  try {
    $resp = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
    if ($resp.StatusCode -eq 200) { $ready = $true; break }
  } catch { }
  if ($elapsed - $lastBootBeat -ge 60) {
    $lastBootBeat = $elapsed
    $noteIndex = [Math]::Min($bootNotes.Count - 1, [int][Math]::Floor($elapsed / 60) - 1)
    if ($noteIndex -lt 0) { $noteIndex = 0 }
    WarnMsg ("{0} ({1}m {2}s)" -f $bootNotes[$noteIndex], [int]($elapsed / 60), ($elapsed % 60))
  }
  Start-Sleep -Seconds 2
}
Write-Progress -Activity 'SuperSQE first boot' -Completed
if (-not $ready) { WarnMsg 'The server is still starting. It will be ready in a few minutes.' }

# ---- Welcome Pack --------------------------------------------------------
$welcomeText = $null
if (Test-Path $welcome) { $welcomeText = Get-Content $welcome -Raw }
elseif (Test-Path $creds) { $welcomeText = Get-Content $creds -Raw }

# The actual port may differ from the requested one on upgrades.
$actualPort = $Port
if ($welcomeText) {
  $m = [regex]::Match($welcomeText, 'http://localhost:(\d+)')
  if ($m.Success) { $actualPort = [int]$m.Groups[1].Value }
}

Step 'Installation complete'
Write-Host ""
Write-Host "  SuperSQE is installed and running." -ForegroundColor Green
Write-Host "  URL:      http://localhost:$actualPort"
Write-Host "  Data dir: $dataDir"
Write-Host ""
Write-Host "  Welcome Pack:            $welcome"
Write-Host "  Administrator credentials: $creds"
Write-Host "  (open the credentials file with Notepad - it is protected to your account)"
Write-Host ""

if ($welcomeText) {
  Write-Host '---------------------------- Welcome Pack ----------------------------' -ForegroundColor Cyan
  Write-Host $welcomeText
  Write-Host '----------------------------------------------------------------------' -ForegroundColor Cyan
} else {
  WarnMsg "Welcome Pack not written yet. Read it shortly at: $welcome"
}

# An upgrade keeps the existing administrator account and does not print the
# password again. Point the user at the saved credentials file.
if ($welcomeText -and ($welcomeText -notmatch 'Password')) {
  WarnMsg 'This was an upgrade - your existing administrator account is unchanged.'
  WarnMsg "Read the saved credentials (run as Administrator): Get-Content '$creds'"
}

Write-Host ""
Write-Host "  Tip: change the port on an existing install by editing" -ForegroundColor DarkGray
Write-Host "       $existingCfg and restarting the 'SuperSQE Server' service." -ForegroundColor DarkGray
Write-Host ""

Start-Process "http://localhost:$actualPort"
