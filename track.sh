#!/usr/bin/env bash
set -euo pipefail

# Ensure .env exists (copy example or create minimal defaults)
if [ ! -f .env ]; then
  if [ -f .env.example ]; then
    cp .env.example .env
    echo "Created .env from .env.example"
  else
    cat > .env <<'EOF'
PORT=5000
AUTO_OPEN_LATEST=false
MESSAGE_PREFIX="Hi! Please tap this secure link to share your location: "
# BASE_URL= https://your-app.example.com
# NGROK_AUTHTOKEN= # paste your ngrok authtoken to avoid auth errors
# TWILIO_SID=AC...
# TWILIO_TOKEN=...
# TWILIO_FROM=+1...
# TARGET_NUMBER=
# IP_GEOLOOKUP=false
EOF
    echo "Created minimal .env with sensible defaults"
  fi
fi

# Load env
# shellcheck disable=SC1091
source .env

PORT=${PORT:-${PORT:-5000}}
MESSAGE_PREFIX=${MESSAGE_PREFIX:-"Hi! Please tap this secure link to share your location: "}

# Ensure pyngrok downloads binary to a writable project-local folder
export PYNGROK_DOWNLOAD_PATH="$(pwd)/.ngrok-bin"
mkdir -p "$PYNGROK_DOWNLOAD_PATH" >/dev/null 2>&1 || true

# If running as root (e.g., via sudo), allow ngrok to run
if [ "$(id -u)" = "0" ]; then
  export NGROK_ALLOW_ROOT=true
fi

# Force a local temporary directory so pyngrok doesn't use /tmp
export TMPDIR="$(pwd)/.tmp"
mkdir -p "$TMPDIR" >/dev/null 2>&1 || true

# Preconditions
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }
need python
need curl

# If no BASE_URL and no NGROK_AUTHTOKEN and ngrok CLI missing, ask user for one
if [ -z "${BASE_URL:-}" ] && [ -z "${NGROK_AUTHTOKEN:-}" ] && ! command -v ngrok >/dev/null 2>&1; then
  echo "No BASE_URL set and ngrok CLI not found."
  echo "Provide either a hosted BASE_URL (recommended) or an ngrok authtoken."
  read -r -p "Enter BASE_URL (leave empty to use ngrok): " INPUT_BASE
  if [ -n "$INPUT_BASE" ]; then
    BASE_URL="$INPUT_BASE"
    # Persist to .env
    if grep -q '^BASE_URL=' .env; then
      sed -i.bak "s|^BASE_URL=.*|BASE_URL=$BASE_URL|" .env || true
    else
      printf '\nBASE_URL=%s\n' "$BASE_URL" >> .env
    fi
  else
    read -r -p "Enter NGROK_AUTHTOKEN (leave empty to skip): " INPUT_TOKEN
    if [ -n "$INPUT_TOKEN" ]; then
      NGROK_AUTHTOKEN="$INPUT_TOKEN"
      if grep -q '^NGROK_AUTHTOKEN=' .env; then
        sed -i.bak "s|^NGROK_AUTHTOKEN=.*|NGROK_AUTHTOKEN=$NGROK_AUTHTOKEN|" .env || true
      else
        printf '\nNGROK_AUTHTOKEN=%s\n' "$NGROK_AUTHTOKEN" >> .env
      fi
    fi
  fi
fi

# Create and use virtualenv for dependencies
if [ ! -d .venv ]; then
  echo "Creating virtual environment (.venv)..."
  python -m venv .venv
fi

# Resolve Python in venv (Windows Git Bash uses Scripts, UNIX uses bin)
if [ -x ".venv/Scripts/python.exe" ]; then
  PY=".venv/Scripts/python.exe"
elif [ -x ".venv/bin/python" ]; then
  PY=".venv/bin/python"
else
  PY="python"
fi

echo "Installing Python dependencies..."
"$PY" -m pip install -q -r requirements.txt || { echo "pip install failed" >&2; exit 1; }

# Start Flask server
echo "Starting Flask server on port ${PORT}..."
PYTHONUNBUFFERED=1 "$PY" server.py &
FLASK_PID=$!
trap 'echo "Shutting down..."; kill $FLASK_PID >/dev/null 2>&1 || true; kill ${NGROK_PID:-} >/dev/null 2>&1 || true; "$PY" -c "from pyngrok import ngrok; ngrok.kill()" >/dev/null 2>&1 || true' EXIT

# Wait a moment to ensure server is up
sleep 1

# Wait for Flask health endpoint
echo -n "Waiting for server health"
for i in {1..20}; do
  if curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
    break
  fi
  echo -n "."
  sleep 0.5
  if [ "$i" -eq 20 ]; then echo "\nServer did not report healthy. Continuing anyway..." >&2; fi
done

if [ -n "${BASE_URL:-}" ]; then
  # Use provided hosted URL
  PUBLIC_URL="$BASE_URL"
  echo "Using BASE_URL: $PUBLIC_URL"
else
  # Start tunnel: prefer ngrok CLI, otherwise pyngrok
  if command -v ngrok >/dev/null 2>&1; then
    # If an authtoken is provided in the environment or .env, configure ngrok for this user (incl. sudo/root)
    if [ -n "${NGROK_AUTHTOKEN:-}" ]; then
      echo "Configuring ngrok authtoken for CLI..."
      ngrok config add-authtoken "$NGROK_AUTHTOKEN" >/dev/null 2>&1 || true
    fi

    echo "Starting ngrok tunnel (CLI)..."
    NGROK_LOG="$TMPDIR/ngrok.log"
    : > "$NGROK_LOG" || true
    ngrok http ${PORT} >"$NGROK_LOG" 2>&1 &
    NGROK_PID=$!
    echo -n "Waiting for ngrok public URL"
    for i in {1..30}; do
      # If ngrok process already exited, show logs and fail fast
      if ! kill -0 "$NGROK_PID" >/dev/null 2>&1; then
        echo "\nngrok exited early. Recent logs:" >&2
        tail -n 80 "$NGROK_LOG" 2>/dev/null >&2 || true
        exit 1
      fi
      if curl -sS http://127.0.0.1:4040/api/tunnels >/dev/null 2>&1; then
        break
      fi
      echo -n "."
      sleep 1
      if [ "$i" -eq 30 ]; then 
        echo "\nngrok did not start. Recent logs:" >&2
        tail -n 80 "$NGROK_LOG" 2>/dev/null >&2 || true
        exit 1
      fi
    done
    TUNNELS_JSON=$(curl -sS http://127.0.0.1:4040/api/tunnels)
    PUBLIC_URL=$(printf '%s' "$TUNNELS_JSON" | sed -n 's/.*"public_url":"\(https:\/\/[^"]*\)".*/\1/p' | head -n1)
    if [ -z "$PUBLIC_URL" ]; then
      echo "Failed to obtain ngrok public URL. Recent logs:" >&2
      tail -n 80 "$NGROK_LOG" 2>/dev/null >&2 || true
      echo "Falling back to pyngrok..." >&2
      # Attempt pyngrok fallback inline
      PUBLIC_URL=$("$PY" - <<'PY'
import os, pathlib, zipfile, sys
from pyngrok import ngrok
from pyngrok.conf import PyngrokConfig

port = int(os.environ.get('PORT','5000'))
token = os.environ.get('NGROK_AUTHTOKEN')
bin_dir = os.environ.get('PYNGROK_DOWNLOAD_PATH') or os.path.join(os.getcwd(), '.ngrok-bin')
pathlib.Path(bin_dir).mkdir(parents=True, exist_ok=True)
ngrok_path = os.path.join(bin_dir, 'ngrok')

# Ensure a local tmp directory
tmp_dir = os.environ.get('TMPDIR') or os.path.join(os.getcwd(), '.tmp')
pathlib.Path(tmp_dir).mkdir(parents=True, exist_ok=True)
os.environ.setdefault('TMPDIR', tmp_dir)

cfg = PyngrokConfig(ngrok_path=ngrok_path, auth_token=token)
if token:
    try:
        ngrok.set_auth_token(token, pyngrok_config=cfg)
    except Exception:
        pass
try:
    t = ngrok.connect(addr=port, proto='http', pyngrok_config=cfg)
    print(t.public_url)
except Exception as e:
    sys.exit(1)
PY
      )
      if [ -z "$PUBLIC_URL" ]; then
        echo "pyngrok fallback also failed." >&2
        exit 1
      fi
    fi
  else
    echo "ngrok CLI not found. Using pyngrok fallback..."
    # Use pyngrok to create a tunnel and print the URL
    # Ensure ngrok binary exists locally to avoid pyngrok downloading into /tmp
    if [ ! -x "$PYNGROK_DOWNLOAD_PATH/ngrok" ]; then
      echo "Preparing local ngrok binary..."
      NGrokURL="https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-amd64.zip"
      DL_ZIP="$TMPDIR/ngrok.zip"
      rm -f "$DL_ZIP" 2>/dev/null || true
      curl -fsSL -o "$DL_ZIP" "$NGrokURL" || { echo "Failed to download ngrok" >&2; exit 1; }
      "$PY" - <<PY || { echo "Failed to extract ngrok" >&2; exit 1; }
import os, zipfile
zip_path = os.environ['TMPDIR'] + '/ngrok.zip'
out_dir = os.environ['PYNGROK_DOWNLOAD_PATH']
with zipfile.ZipFile(zip_path, 'r') as z:
    z.extractall(out_dir)
PY
      chmod +x "$PYNGROK_DOWNLOAD_PATH/ngrok" || true
    fi
    PUBLIC_URL=$("$PY" - <<'PY'
import os
import pathlib
from pyngrok import ngrok
from pyngrok.conf import PyngrokConfig

port = int(os.environ.get('PORT','5000'))
token = os.environ.get('NGROK_AUTHTOKEN')

# Ensure local, writable ngrok path
bin_dir = os.environ.get('PYNGROK_DOWNLOAD_PATH') or os.path.join(os.getcwd(), '.ngrok-bin')
pathlib.Path(bin_dir).mkdir(parents=True, exist_ok=True)
ngrok_path = os.path.join(bin_dir, 'ngrok')

# Allow root if needed
os.environ.setdefault('NGROK_ALLOW_ROOT', 'true' if os.geteuid()==0 else 'false')

# Ensure a local tmp directory (avoid /tmp perms under sudo)
tmp_dir = os.environ.get('TMPDIR') or os.path.join(os.getcwd(), '.tmp')
pathlib.Path(tmp_dir).mkdir(parents=True, exist_ok=True)
os.environ.setdefault('TMPDIR', tmp_dir)

cfg = PyngrokConfig(ngrok_path=ngrok_path, auth_token=token)
if token:
    try:
        ngrok.set_auth_token(token, pyngrok_config=cfg)
    except Exception:
        pass

t = ngrok.connect(addr=port, proto='http', pyngrok_config=cfg)
print(t.public_url)
PY
    )
    if [ -z "$PUBLIC_URL" ]; then
      echo "Failed to obtain public URL via pyngrok" >&2
      exit 1
    fi
  fi
fi

echo "\nPublic URL: $PUBLIC_URL"
CAPTURE_URL="$PUBLIC_URL/"
LATEST_URL="$PUBLIC_URL/latest"

echo "Capture page: $CAPTURE_URL"
echo "Latest view:  $LATEST_URL"

# Try to open the Latest view automatically if enabled
AUTO_OPEN_LATEST=${AUTO_OPEN_LATEST:-false}
if [ "$AUTO_OPEN_LATEST" = "true" ]; then
  open_browser() {
    url="$1"
    if command -v xdg-open >/dev/null 2>&1; then
      xdg-open "$url" >/dev/null 2>&1 || true
    elif command -v open >/dev/null 2>&1; then
      open "$url" >/dev/null 2>&1 || true
    else
      # Windows Git Bash fallback
      command -v cmd.exe >/dev/null 2>&1 && cmd.exe /c start "" "$url" >/dev/null 2>&1 || true
    fi
  }
  open_browser "$LATEST_URL"
fi

## Ask for phone number (use .env default if present)
while true; do
  read -r -p "Enter consenting recipient phone number in E.164 format${TARGET_NUMBER:+ [${TARGET_NUMBER}]} (or press Enter to skip SMS): " INPUT_NUMBER
  if [ -z "$INPUT_NUMBER" ]; then
    # keep existing or empty to skip SMS
    break
  fi
  if printf '%s' "$INPUT_NUMBER" | grep -Eq '^\+[1-9][0-9]{7,14}$'; then
    TARGET_NUMBER="$INPUT_NUMBER"
    break
  else
    echo "Invalid format. Example: +15551234567"
  fi
done

# Send SMS via Twilio
if [ -z "${TWILIO_SID:-}" ] || [ -z "${TWILIO_TOKEN:-}" ] || [ -z "${TWILIO_FROM:-}" ]; then
  echo "Skipping SMS: TWILIO_* not set in .env" >&2
elif [ -z "${TARGET_NUMBER:-}" ]; then
  echo "Skipping SMS: no target number provided." >&2
else
  # Append phone number as query parameter to link (URL-encoded)
  PHONE_ENC=$(python -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$TARGET_NUMBER")
  LINK_WITH_FROM="$CAPTURE_URL?from=$PHONE_ENC"
  BODY="$MESSAGE_PREFIX $LINK_WITH_FROM"
  echo "Sending SMS to $TARGET_NUMBER from $TWILIO_FROM..."
  RESP=$(curl -sS -u "$TWILIO_SID:$TWILIO_TOKEN" -X POST \
    https://api.twilio.com/2010-04-01/Accounts/$TWILIO_SID/Messages.json \
    --data-urlencode "To=$TARGET_NUMBER" \
    --data-urlencode "From=$TWILIO_FROM" \
    --data-urlencode "Body=$BODY") || true
  if echo "$RESP" | grep -q '"status"'; then
    echo "SMS sent (check Twilio console if not received)."
  else
    echo "Twilio API response:"; echo "$RESP"
  fi
fi

echo "\n========================================"
echo "  Location Share is Running"
echo "  Capture: $CAPTURE_URL"
echo "  Latest : $LATEST_URL"
if [ -n "${TARGET_NUMBER:-}" ]; then
  echo "  Target : $TARGET_NUMBER"
fi
echo "----------------------------------------"
echo "Ask the consenting user to open the Capture link and allow location."
echo "View updates live at the Latest link. Press Ctrl+C to stop."
echo "========================================\n"

# Tail logs until Ctrl+C
echo "\nPress Ctrl+C to stop. Open: $LATEST_URL"
wait
