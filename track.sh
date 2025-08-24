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

# Preconditions
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }
need python
need curl

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
    echo "Starting ngrok tunnel (CLI)..."
    ngrok http ${PORT} >/dev/null 2>&1 &
    NGROK_PID=$!
    echo -n "Waiting for ngrok public URL"
    for i in {1..30}; do
      if curl -sS http://127.0.0.1:4040/api/tunnels >/dev/null 2>&1; then
        break
      fi
      echo -n "."
      sleep 1
      if [ "$i" -eq 30 ]; then echo "\nngrok did not start." >&2; exit 1; fi
    done
    TUNNELS_JSON=$(curl -sS http://127.0.0.1:4040/api/tunnels)
    PUBLIC_URL=$(printf '%s' "$TUNNELS_JSON" | sed -n 's/.*"public_url":"\(https:\/\/[^\"]*\)".*/\1/p' | head -n1)
    if [ -z "$PUBLIC_URL" ]; then
      echo "Failed to obtain ngrok public URL" >&2
      exit 1
    fi
  else
    echo "ngrok CLI not found. Using pyngrok fallback..."
    # Use pyngrok to create a tunnel and print the URL
    PUBLIC_URL=$("$PY" - <<'PY'
import os
from pyngrok import ngrok
port = int(os.environ.get('PORT','5000'))
t = ngrok.connect(addr=port, proto='http')
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
