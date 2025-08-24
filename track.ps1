#!/usr/bin/env pwsh
# PowerShell orchestrator to run the Flask server, start ngrok, and send SMS via Twilio
# Designed for quick clone-and-run usage on Windows.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Need($name) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
    throw "Missing dependency: $name"
  }
}

function Load-EnvFile($path) {
  if (-not (Test-Path $path)) { return @{} }
  $vars = @{}
  Get-Content $path | ForEach-Object {
    if ($_ -match '^(#|\s*$)') { return }
    $k,$v = $_ -split '=',2
    if ($null -ne $k -and $null -ne $v) { $vars[$k.trim()] = $v.trim().Trim('"') }
  }
  return $vars
}

function Save-EnvFile($path, $vars) {
  $lines = @()
  foreach ($k in $vars.Keys) { $lines += "$k=$($vars[$k])" }
  Set-Content -Path $path -Value $lines -Encoding UTF8
}

# 1) Check prerequisites
Need python

# 2) Ensure virtual environment and install deps
$venv = Join-Path $PSScriptRoot '.venv'
$py = 'python'
if (-not (Test-Path $venv)) {
  Write-Host 'Creating virtual environment (.venv)...'
  & $py -m venv $venv
}
$venvPy = Join-Path $venv 'Scripts\python.exe'
$venvPip = Join-Path $venv 'Scripts\pip.exe'
Write-Host 'Installing Python dependencies...'
& $venvPip install -r (Join-Path $PSScriptRoot 'requirements.txt') | Out-Host

# 3) Load or create .env (no prompts)
$envPath = Join-Path $PSScriptRoot '.env'
if (-not (Test-Path $envPath)) {
  $example = Join-Path $PSScriptRoot '.env.example'
  if (Test-Path $example) {
    Copy-Item $example $envPath -Force
    Write-Host 'Created .env from .env.example'
  } else {
    @(
      'PORT=5000'
      'AUTO_OPEN_LATEST=false'
      'MESSAGE_PREFIX="Hi! Please tap this secure link to share your location: "'
      '# BASE_URL= https://your-app.example.com'
      '# TWILIO_SID=AC...'
      '# TWILIO_TOKEN=...'
      '# TWILIO_FROM=+1...'
      '# TARGET_NUMBER='
      '# IP_GEOLOOKUP=false'
    ) | Set-Content -Path $envPath -Encoding UTF8
    Write-Host 'Created minimal .env with sensible defaults'
  }
}

# Re-load to capture any manual edits
$envVars = Load-EnvFile $envPath
$PORT = [int]($envVars['PORT'])
$MESSAGE_PREFIX = if ($envVars.ContainsKey('MESSAGE_PREFIX')) { $envVars['MESSAGE_PREFIX'] } else { 'Hi! Please tap this secure link to share your location: ' }
# Export NGROK_AUTHTOKEN to environment if present
if ($envVars.ContainsKey('NGROK_AUTHTOKEN') -and -not [string]::IsNullOrWhiteSpace($envVars['NGROK_AUTHTOKEN'])) {
  $env:NGROK_AUTHTOKEN = $envVars['NGROK_AUTHTOKEN']
}

# If no BASE_URL and no NGROK_AUTHTOKEN and ngrok CLI missing, ask user for one and persist to .env
$hasBase = ($envVars.ContainsKey('BASE_URL') -and -not [string]::IsNullOrWhiteSpace($envVars['BASE_URL']))
$hasToken = ($envVars.ContainsKey('NGROK_AUTHTOKEN') -and -not [string]::IsNullOrWhiteSpace($envVars['NGROK_AUTHTOKEN']))
$ngrokCli = Get-Command ngrok -ErrorAction SilentlyContinue
if (-not $hasBase -and -not $hasToken -and -not $ngrokCli) {
  Write-Host 'No BASE_URL set and ngrok CLI not found.'
  Write-Host 'Provide either a hosted BASE_URL (recommended) or an ngrok authtoken.'
  $inputBase = Read-Host 'Enter BASE_URL (leave empty to use ngrok)'
  if (-not [string]::IsNullOrWhiteSpace($inputBase)) {
    $envVars['BASE_URL'] = $inputBase
  } else {
    $inputToken = Read-Host 'Enter NGROK_AUTHTOKEN (leave empty to skip)'
    if (-not [string]::IsNullOrWhiteSpace($inputToken)) {
      $envVars['NGROK_AUTHTOKEN'] = $inputToken
      $env:NGROK_AUTHTOKEN = $inputToken
    }
  }
  # Persist updates to .env
  Save-EnvFile $envPath $envVars
}

# 4) Start Flask server
Write-Host "Starting Flask server on port $PORT..."
$server = Start-Process -FilePath $venvPy -ArgumentList @((Join-Path $PSScriptRoot 'server.py')) -NoNewWindow -PassThru -WorkingDirectory $PSScriptRoot -Env @{"PORT"=$PORT}
Start-Sleep -Milliseconds 800

# Wait for /health
Write-Host -NoNewline 'Waiting for server health'
for ($i=0; $i -lt 20; $i++) {
  try {
    Invoke-RestMethod -Uri "http://127.0.0.1:$PORT/health" -TimeoutSec 2 -ErrorAction Stop | Out-Null
    break
  } catch {}
  Write-Host -NoNewline '.'
  Start-Sleep -Milliseconds 500
}

# 5) Determine public URL (BASE_URL or ngrok)
if ($envVars.ContainsKey('BASE_URL') -and -not [string]::IsNullOrWhiteSpace($envVars['BASE_URL'])) {
  $publicUrl = $envVars['BASE_URL']
  Write-Host "Using BASE_URL: $publicUrl"
} else {
  # Prefer ngrok CLI; fallback to pyngrok
  $ngrokCli = Get-Command ngrok -ErrorAction SilentlyContinue
  if ($ngrokCli) {
    Write-Host 'Starting ngrok tunnel (CLI)...'
    $ngrok = Start-Process -FilePath 'ngrok' -ArgumentList @('http', "$PORT") -NoNewWindow -PassThru -WorkingDirectory $PSScriptRoot
    # Poll ngrok API for public URL
    Write-Host -NoNewline 'Waiting for ngrok public URL'
    $publicUrl = $null
    for ($i=0; $i -lt 30; $i++) {
      try {
        $resp = Invoke-RestMethod -Uri 'http://127.0.0.1:4040/api/tunnels' -TimeoutSec 2 -ErrorAction Stop
        $publicUrl = ($resp.tunnels | Where-Object { $_.public_url -like 'https://*' } | Select-Object -First 1).public_url
        if ($publicUrl) { break }
      } catch {}
      Write-Host -NoNewline '.'
      Start-Sleep -Seconds 1
    }
    if (-not $publicUrl) { throw 'ngrok did not provide a public URL.' }
  } else {
    Write-Host 'ngrok CLI not found. Using pyngrok fallback...'
    # Ensure token is available to the child process
    if ($envVars.ContainsKey('NGROK_AUTHTOKEN') -and -not [string]::IsNullOrWhiteSpace($envVars['NGROK_AUTHTOKEN'])) { $env:NGROK_AUTHTOKEN = $envVars['NGROK_AUTHTOKEN'] }
    $publicUrl = & $venvPy - << 'PY'
import os
from pyngrok import ngrok
port = int(os.environ.get('PORT','5000'))
# set authtoken if provided
token = os.environ.get('NGROK_AUTHTOKEN')
if token:
    try:
        ngrok.set_auth_token(token)
    except Exception:
        pass
tunnel = ngrok.connect(addr=port, proto='http')
print(tunnel.public_url)
PY
    if (-not $publicUrl) { throw 'Failed to obtain public URL via pyngrok.' }
  }
}
Write-Host "`nPublic URL: $publicUrl"

$CAPTURE_URL = "$publicUrl/"
$LATEST_URL = "$publicUrl/latest"
Write-Host "Capture page: $CAPTURE_URL"
Write-Host "Latest view:  $LATEST_URL"

# Auto-open Latest dashboard if enabled
$autoOpen = if ($envVars.ContainsKey('AUTO_OPEN_LATEST')) { $envVars['AUTO_OPEN_LATEST'] } else { 'false' }
if ($autoOpen -and ($autoOpen.ToLower() -eq 'true')) {
  try { Start-Process $LATEST_URL | Out-Null } catch {}
}

# 7) Ask for phone number, confirm consent
$defaultNum = if ($envVars.ContainsKey('TARGET_NUMBER')) { $envVars['TARGET_NUMBER'] } else { '' }
while ($true) {
  $prompt = 'Enter consenting recipient phone number in E.164 format'
  if ($defaultNum) { $prompt += " [$defaultNum]" }
  $inputNum = Read-Host $prompt
  if ([string]::IsNullOrWhiteSpace($inputNum)) { $inputNum = $defaultNum }
  if ([string]::IsNullOrWhiteSpace($inputNum)) { break }
  if ($inputNum -match '^\+[1-9][0-9]{7,14}$') { break }
  Write-Warning 'Invalid format. Example: +15551234567'
}

# 8) Send SMS via Twilio (if configured and consented)
$haveTwilio = $envVars['TWILIO_SID'] -and $envVars['TWILIO_TOKEN'] -and $envVars['TWILIO_FROM']
if ($haveTwilio -and -not [string]::IsNullOrWhiteSpace($inputNum)) {
  $phoneEnc = [uri]::EscapeDataString($inputNum)
  $linkWithFrom = "$CAPTURE_URL?from=$phoneEnc"
  $body = "$MESSAGE_PREFIX $linkWithFrom"
  Write-Host "Sending SMS to $inputNum from $($envVars['TWILIO_FROM'])..."
  $twilioAuth = (
    [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($envVars['TWILIO_SID']):$($envVars['TWILIO_TOKEN'])"))
  )
  try {
    $resp = Invoke-RestMethod -Method Post -Uri "https://api.twilio.com/2010-04-01/Accounts/$($envVars['TWILIO_SID'])/Messages.json" -Headers @{ Authorization = "Basic $twilioAuth" } -Body @{
      To   = $inputNum
      From = $envVars['TWILIO_FROM']
      Body = $body
    }
    Write-Host 'SMS sent (check Twilio console if not received).'
  } catch {
    Write-Warning ("Twilio API error: " + $_)
  }
} else {
  Write-Warning 'Skipping SMS: Twilio not configured or no number provided. You can copy the capture link manually.'
}

Write-Host '========================================'
Write-Host '  Location Share is Running'
Write-Host "  Capture: $CAPTURE_URL"
Write-Host "  Latest : $LATEST_URL"
if (-not [string]::IsNullOrWhiteSpace($inputNum)) { Write-Host "  Target : $inputNum" }
Write-Host '----------------------------------------'
Write-Host 'Ask the consenting user to open the Capture link and allow location.'
Write-Host 'View updates live at the Latest link. Press Ctrl+C to stop.'
Write-Host '========================================'
Write-Host "`nPress Ctrl+C in this window to stop. Open: $LATEST_URL"

# 9) Wait; handle Ctrl+C to stop processes
try {
  while ($true) { Start-Sleep -Seconds 3600 }
} finally {
  Write-Host 'Shutting down...'
  if ($server -and -not $server.HasExited) { try { $server.Kill() } catch {} }
  if ($ngrok -and -not $ngrok.HasExited) { try { $ngrok.Kill() } catch {} }
  try { & $venvPy -c "from pyngrok import ngrok; ngrok.kill()" | Out-Null } catch {}
}
