# Consent-Based Location Sharing (Bash + Flask)

This app lets you send an SMS link to a consenting person. When they open it and allow location in their browser, their GPS coordinates are sent to your server and shown on a small map.

Important: Use only with explicit consent. Explain what will be collected and how it will be used.

## Components
- `server.py` (Flask):
  - `GET /` capture page requesting geolocation.
  - `POST /loc` receives `{ lat, lon, accuracy, ts, deviceInfo }` and stores latest in memory and appends to `data/locations.json` (JSON lines).
  - `GET /latest` simple Leaflet map view.
  - `GET /latest.json` latest raw JSON.
- `templates/index.html`: capture page UI.
- `track.sh`: Bash script that launches Flask, starts ngrok, discovers public URL, and sends an SMS via Twilio with the capture link.
- `.env.example`: configuration template.
- `requirements.txt`: Python dependencies.

## Prerequisites
- Python 3.10+
- ngrok installed and authenticated (`ngrok config add-authtoken <token>`)
- Optional for SMS: Twilio account (SID, Auth Token, SMS-capable number)
- Windows: you can use PowerShell (`track.ps1`) or Git Bash (`track.sh`).

## Setup
1. Create a virtual environment (recommended):
   - PowerShell:
     ```powershell
     py -m venv .venv
     .venv\Scripts\Activate.ps1
     pip install -r requirements.txt
     ```
   - Git Bash:
     ```bash
     python -m venv .venv
     source .venv/Scripts/activate
     pip install -r requirements.txt
     ```
2. Copy env file:
   ```bash
   cp .env.example .env
   ```
   Fill in: `PORT`, `TWILIO_SID`, `TWILIO_TOKEN`, `TWILIO_FROM`, `TARGET_NUMBER`, optionally `MESSAGE_PREFIX`.
3. Ensure ngrok is installed and authenticated:
   ```bash
   ngrok config add-authtoken <YOUR_NGROK_TOKEN>
   ```

## Quick Start (Clone and Run)

### PowerShell (Windows)
```powershell
git clone <this-repo> location
cd location
.\track.ps1
```
- What it does automatically:
  - Creates `.venv` and installs `requirements.txt`.
  - Starts Flask server and ngrok, prints public links.
  - Prompts for the consenting phone number and confirms consent.
  - If Twilio env values are present, sends an SMS with the capture link containing the phone (`?from=<number>`). Otherwise, just copy the printed link.

Tip: If PowerShell blocks the script, allow running local scripts once:
```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

### Git Bash (Windows) or Linux/macOS
```bash
git clone <this-repo> location
cd location
bash track.sh
```
- Similar behavior to PowerShell script: auto-creates `.venv`, installs deps, runs server + ngrok, prompts for phone + consent, and optionally sends Twilio SMS.

## Detailed Setup (Recommended)

Follow these steps for a reliable first run.

1) Create `.env` (do not only edit `.env.example`)

- Copy once, then edit:
  ```bash
  cp .env.example .env
  ```
- Open `.env` and set at least one of:
  - `BASE_URL=https://your-hosted-url` (skip ngrok), or
  - `NGROK_AUTHTOKEN=<your_verified_ngrok_token>` to use ngrok.
- Optional SMS:
  - `TWILIO_SID=AC...`
  - `TWILIO_TOKEN=...`
  - `TWILIO_FROM=+1XXXXXXXXXX` (SMS-capable number)
  - `TARGET_NUMBER=+<countrycode><number>` (default recipient)

2) Install dependencies

- Windows (PowerShell):
  ```powershell
  py -m venv .venv
  .venv\Scripts\Activate.ps1
  pip install -r requirements.txt
  ```
- Bash (Git Bash/WSL/macOS/Linux):
  ```bash
  python -m venv .venv
  source .venv/Scripts/activate  # Windows Git Bash
  # or source .venv/bin/activate  # Linux/macOS
  pip install -r requirements.txt
  ```

3) ngrok (if not using BASE_URL)

- Install ngrok and add your token (same user you will run the script as):
  ```bash
  ngrok config add-authtoken <YOUR_NGROK_TOKEN>
  ```
- Alternatively, keep `NGROK_AUTHTOKEN` in `.env` and the scripts will configure it.

4) Run

- Windows: `./track.ps1`
- Bash: `bash track.sh` (avoid `sudo` unless necessary)

5) Share the printed "Capture" link with the consenting user

- They must open the HTTPS link and allow location. View live updates at `/latest`.

## Enable SMS Sending (Twilio)

To auto-send the capture link via SMS:

- In `.env`, set:
  ```
  TWILIO_SID=ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
  TWILIO_TOKEN=your_auth_token_here
  TWILIO_FROM=+1XXXXXXXXXX
  ```
- Trial account notes:
  - You can only message verified recipient numbers.
  - Enable target country under Messaging Geo Permissions.
- The script uses the number you input at runtime or `TARGET_NUMBER` in `.env` and sends the capture link (`/`) with `?from=<phone>` added.

## ngrok Troubleshooting

- `ERR_NGROK_4018` (auth required):
  - Use a verified ngrok account and token.
  - Put the token in `.env` as `NGROK_AUTHTOKEN=...` or run `ngrok config add-authtoken ...`.
- `ERR_NGROK_108` (one agent session):
  - Stop existing sessions (Dashboard: Agents) or kill local processes:
    - Linux/WSL: `pkill -f ngrok || true`
    - Windows: `taskkill /IM ngrok.exe /F`
  - Also clear pyngrok tunnels: `python -c "from pyngrok import ngrok; ngrok.kill()"`
- Using `sudo` can use a different ngrok config profile. Prefer running without `sudo`.
- If ngrok CLI fails, the script falls back to `pyngrok` and prints logs from `./.tmp/ngrok.log`.

## Notes

- Files:
  - `server.py`, `track.sh`, `track.ps1`, `templates/index.html`, `.env`, `.env.example`.
- Data:
  - Logs appended to `data/locations.json` (JSONL). Consider rotating or purging periodically.

## Manual run (without Bash)
- In one terminal:
  ```bash
  python server.py
  ```
- In another:
  ```bash
  ngrok http 5000
  ```
- Send the public URL root to the consenting user.

## Phone association
- The SMS/link includes a query parameter `?from=<phone>`. The capture page forwards this as `phone` to `POST /loc`.
- The backend stores `phone` in each record and displays it on `/latest` and `/latest.json`.

## Data storage
- Latest location is kept in memory until restart.
- All received locations are appended to `data/locations.json` as one JSON object per line.
- Consider purging this file regularly or adding retention logic.

## Privacy & Consent
- Obtain explicit consent before sending the link.
- Disclose that you collect GPS coordinates, accuracy, device user-agent, server-observed IP, and timestamps.
- Secure your ngrok URL and do not share it publicly.
- Use HTTPS links (ngrok provides `https://`).

## Troubleshooting
- SMS: ensure `TWILIO_SID`, `TWILIO_TOKEN`, `TWILIO_FROM` are set and numbers are E.164 formatted.
- ngrok: verify it's installed and local API `http://127.0.0.1:4040` is reachable.
- Geolocation: requires HTTPS (ngrok provides it) and user permission on the device.
