#!/usr/bin/env python3
import os
import json
import time
import threading
from pathlib import Path
from flask import Flask, request, jsonify, render_template, send_from_directory

# Optional external lookup
try:
    import requests  # for IP geolocation fallback
except Exception:  # pragma: no cover
    requests = None

app = Flask(__name__, template_folder="templates", static_folder="static")

# Storage
DATA_DIR = Path("data")
DATA_DIR.mkdir(parents=True, exist_ok=True)
DATA_FILE = DATA_DIR / "locations.json"

_latest_lock = threading.Lock()
_latest_location = None  # dict or None


def _append_location(record: dict):
    # Append record to a JSON lines file for simplicity
    with open(DATA_FILE, "a", encoding="utf-8") as f:
        f.write(json.dumps(record) + "\n")


def _ip_geo_lookup(ip: str):
    """Return (lat, lon, meta) or (None, None, meta) using a public API if allowed."""
    if not os.environ.get("IP_GEOLOOKUP", "false").lower() == "true":
        return None, None, {}
    if requests is None:
        return None, None, {"error": "requests not installed"}
    try:
        # ipapi.co is a free, rate-limited service suitable for demos
        resp = requests.get(f"https://ipapi.co/{ip}/json/", timeout=3)
        if resp.ok:
            j = resp.json()
            lat = j.get("latitude")
            lon = j.get("longitude")
            meta = {
                "city": j.get("city"),
                "region": j.get("region"),
                "country": j.get("country_name"),
                "org": j.get("org"),
            }
            try:
                if lat is not None and lon is not None:
                    return float(lat), float(lon), meta
            except Exception:
                pass
            return None, None, meta
    except Exception:
        return None, None, {"error": "lookup_failed"}
    return None, None, {}


@app.route("/")
def index():
    return render_template("index.html")


@app.route("/loc", methods=["POST"]) 
def receive_location():
    try:
        data = request.get_json(force=True, silent=False)
    except Exception:
        return jsonify({"ok": False, "error": "Invalid JSON"}), 400

    if not isinstance(data, dict):
        return jsonify({"ok": False, "error": "Invalid payload"}), 400

    lat = data.get("lat")
    lon = data.get("lon")
    accuracy = data.get("accuracy")
    ts = data.get("ts")
    device = data.get("deviceInfo")
    phone = data.get("phone")
    name = data.get("name")

    if lat is None or lon is None:
        return jsonify({"ok": False, "error": "lat/lon required"}), 400

    record = {
        "lat": float(lat),
        "lon": float(lon),
        "accuracy": accuracy,
        "client_ts": ts,
        "server_ts": int(time.time()*1000),
        "deviceInfo": device,
        "phone": phone,
        "name": name,
        "ip": request.headers.get('X-Forwarded-For', request.remote_addr),
        "ua": request.headers.get('User-Agent'),
    }

    with _latest_lock:
        global _latest_location
        _latest_location = record
    _append_location(record)

    # Log to console for operator visibility
    try:
        print(
            f"[loc] name={record.get('name') or 'n/a'} "
            f"phone={record.get('phone') or 'n/a'} "
            f"lat={record['lat']:.6f} lon={record['lon']:.6f} "
            f"acc={record.get('accuracy') or 'n/a'}m "
            f"server_ts={record['server_ts']}",
            flush=True
        )
    except Exception:
        pass

    return jsonify({"ok": True})


@app.route("/latest")
def latest_page():
    # Render a tiny page showing latest location and an OSM map via Leaflet CDN
    return (
        """
        <!doctype html>
        <html>
        <head>
          <meta charset=\"utf-8\" />
          <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />
          <title>Latest Location</title>
          <link rel=\"stylesheet\" href=\"https://unpkg.com/leaflet@1.9.4/dist/leaflet.css\" integrity=\"sha256-p4NxAoJBhIIN+hmNHrzRCf9tD/miZyoHS5obTRR9BMY=\" crossorigin=\"\"/>
          <style>body{font-family:system-ui,Segoe UI,Roboto,Arial,sans-serif;margin:0;padding:16px;} #map{height:60vh;border:1px solid #ddd;border-radius:8px;} .card{padding:12px;border:1px solid #eee;border-radius:8px;margin-bottom:12px;} code{background:#f6f8fa;padding:2px 4px;border-radius:4px;}</style>
        </head>
        <body>
          <h2>Latest Location</h2>
          <div id=\"info\" class=\"card\">Loading...</div>
          <div id=\"map\"></div>
          <script src=\"https://unpkg.com/leaflet@1.9.4/dist/leaflet.js\" integrity=\"sha256-20nQCchB9co0qIjJZRGuk2/Z9VM+kNiyxNV1lvTlZBo=\" crossorigin=\"\"></script>
          <script>
            const info = document.getElementById('info');
            async function fetchLatest() {
              const res = await fetch('/latest.json');
              if (!res.ok) { info.textContent = 'No data yet'; return null; }
              return res.json();
            }
            function render(latest){
              if (!latest) { info.textContent = 'No data yet.'; return; }
              info.innerHTML = `<div><strong>Name:</strong> ${latest.name || 'n/a'}</div>
                                <div><strong>Phone:</strong> ${latest.phone || 'n/a'}</div>
                                <div><strong>Lat:</strong> ${latest.lat} <strong>Lon:</strong> ${latest.lon} <strong>Accuracy:</strong> ${latest.accuracy || 'n/a'}m</div>
                                <div><strong>Client TS:</strong> ${latest.client_ts || 'n/a'} <strong>Server TS:</strong> ${latest.server_ts}</div>
                                <div><strong>IP:</strong> ${latest.ip || ''} <strong>UA:</strong> <code>${(latest.ua||'').slice(0,120)}</code></div>`;
              const map = L.map('map').setView([latest.lat, latest.lon], 15);
              L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
                maxZoom: 19,
                attribution: '&copy; OpenStreetMap contributors'
              }).addTo(map);
              const m = L.marker([latest.lat, latest.lon]).addTo(map);
              m.bindPopup('Latest location').openPopup();
              if (latest.accuracy) { L.circle([latest.lat, latest.lon], {radius: latest.accuracy, color:'#2a7', fillOpacity:0.15}).addTo(map); }
            }
            fetchLatest().then(render);
          </script>
        </body>
        </html>
        """
    )


@app.route("/latest.json")
def latest_json():
    with _latest_lock:
        if _latest_location is None:
            return jsonify({}), 404
        return jsonify(_latest_location)


@app.route("/health")
def health():
    return jsonify({"ok": True})


@app.route("/iplog", methods=["POST"])
def ip_log():
    """Log an access with IP/UA, and optionally resolve coarse location from IP."""
    try:
        data = request.get_json(force=True, silent=True) or {}
    except Exception:
        data = {}

    phone = data.get("phone")
    name = data.get("name")
    ts = data.get("ts") or int(time.time() * 1000)
    ua = request.headers.get('User-Agent')
    ip = request.headers.get('X-Forwarded-For', request.remote_addr)

    lat, lon, meta = _ip_geo_lookup(ip)

    record = {
        "lat": lat if lat is not None else None,
        "lon": lon if lon is not None else None,
        "accuracy": None,
        "client_ts": ts,
        "server_ts": int(time.time()*1000),
        "deviceInfo": None,
        "phone": phone,
        "name": name,
        "ip": ip,
        "ua": ua,
        "source": "iplog",
        "meta": meta,
    }

    # Only update latest if we have coordinates
    if record["lat"] is not None and record["lon"] is not None:
        with _latest_lock:
            global _latest_location
            _latest_location = record
    _append_location(record)

    try:
        print(
            f"[iplog] name={record.get('name') or 'n/a'} "
            f"phone={record.get('phone') or 'n/a'} "
            f"ip={record['ip']} ua={(record['ua'] or '')[:60]} "
            f"lat={record['lat'] if record['lat'] is not None else 'n/a'} "
            f"lon={record['lon'] if record['lon'] is not None else 'n/a'}",
            flush=True,
        )
    except Exception:
        pass

    return jsonify({"ok": True, "looked_up": record["lat"] is not None})


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "5000"))
    app.run(host="0.0.0.0", port=port)
