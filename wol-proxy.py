#!/usr/bin/env python3
"""
WOL Proxy — Wake-on-LAN HTTP bridge
Endpoints:
  GET  /wol/resolve?ip=<ip>          Resolve MAC from ARP table (local network only)
  POST /wol/wake                      Send Magic Packet  { "mac": "xx:xx:xx:xx:xx:xx", "broadcast": "255.255.255.255" }
  POST /wol/fritzbox                  Wake via FritzBox TR-064 API { "host": "fritz.box", "mac": "...", "user": "", "password": "" }
  GET  /health                        Liveness check
"""

import json
import re
import socket
import struct
import subprocess
import sys
import urllib.request
import urllib.error
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 9999
CORS_ORIGIN = sys.argv[2] if len(sys.argv) > 2 else "*"


# ── Magic Packet ──────────────────────────────────────────────────────────────

def build_magic_packet(mac: str) -> bytes:
    mac_clean = re.sub(r"[:\-]", "", mac).upper()
    if len(mac_clean) != 12:
        raise ValueError(f"Invalid MAC: {mac!r}")
    mac_bytes = bytes.fromhex(mac_clean)
    return b"\xff" * 6 + mac_bytes * 16


def send_magic_packet(mac: str, broadcast: str = "255.255.255.255", port: int = 9) -> None:
    packet = build_magic_packet(mac)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        s.sendto(packet, (broadcast, port))


# ── ARP resolve ───────────────────────────────────────────────────────────────

def normalize_mac(raw: str) -> str:
    """Normalize MAC to xx:xx:xx:xx:xx:xx, padding single-digit segments (macOS ARP quirk)."""
    sep = "-" if "-" in raw else ":"
    parts = raw.split(sep)
    return ":".join(p.zfill(2) for p in parts)


def resolve_mac_from_arp(ip: str) -> str | None:
    try:
        result = subprocess.run(
            ["arp", "-an"],
            capture_output=True, text=True, timeout=5
        )
        for line in result.stdout.splitlines():
            if ip in line:
                # macOS/Linux format:  host (ip) at aa:bb:cc:dd:ee:ff ...
                m = re.search(r"at\s+([0-9a-fA-F]{1,2}(?:[:\-][0-9a-fA-F]{1,2}){5})", line)
                if m:
                    return normalize_mac(m.group(1))
    except Exception:
        pass
    return None


# ── FritzBox TR-064 WOL ───────────────────────────────────────────────────────

def fritzbox_wol(host: str, mac: str, user: str = "", password: str = "") -> dict:
    """
    Uses FritzBox TR-064 WAN service to send WOL.
    Works for local (fritz.box) and remote (dyndns host) access.
    Port 49000 must be reachable (local) or forwarded (remote — not recommended;
    prefer local-only and use VPN for remote access).
    """
    mac_normalized = mac.replace("-", ":").upper()
    soap_body = f"""<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
            s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:X_AVM-DE_WakeOnLANByMACAddress xmlns:u="urn:dslforum-org:service:Hosts:1">
      <NewMACAddress>{mac_normalized}</NewMACAddress>
    </u:X_AVM-DE_WakeOnLANByMACAddress>
  </s:Body>
</s:Envelope>"""

    url = f"http://{host}:49000/upnp/control/hosts"
    headers = {
        "Content-Type": 'text/xml; charset="utf-8"',
        "SOAPAction": '"urn:dslforum-org:service:Hosts:1#X_AVM-DE_WakeOnLANByMACAddress"',
    }

    req = urllib.request.Request(url, data=soap_body.encode(), headers=headers, method="POST")

    if user:
        import base64
        creds = base64.b64encode(f"{user}:{password}".encode()).decode()
        req.add_header("Authorization", f"Basic {creds}")

    try:
        with urllib.request.urlopen(req, timeout=8) as resp:
            return {"ok": True, "status": resp.status}
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")
        return {"ok": False, "status": e.code, "detail": body}
    except Exception as e:
        return {"ok": False, "error": str(e)}


# ── HTTP handler ──────────────────────────────────────────────────────────────

class Handler(BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        print(f"[wol-proxy] {self.address_string()} {fmt % args}")

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", CORS_ORIGIN)
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    def _json(self, code: int, payload: dict):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self._cors()
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self) -> dict:
        length = int(self.headers.get("Content-Length", 0))
        return json.loads(self.rfile.read(length)) if length else {}

    def do_GET(self):
        parsed = urlparse(self.path)
        qs = parse_qs(parsed.query)

        if parsed.path == "/health":
            self._json(200, {"ok": True})
            return

        if parsed.path == "/wol/resolve":
            ip = qs.get("ip", [""])[0].strip()
            if not ip:
                self._json(400, {"ok": False, "error": "Missing ?ip="})
                return
            mac = resolve_mac_from_arp(ip)
            if mac:
                self._json(200, {"ok": True, "ip": ip, "mac": mac})
            else:
                self._json(404, {"ok": False, "error": f"MAC not found for {ip}. Is the host reachable on this network?"})
            return

        self._json(404, {"ok": False, "error": "Not found"})

    def do_POST(self):
        parsed = urlparse(self.path)

        if parsed.path == "/wol/wake":
            data = self._read_json()
            mac = data.get("mac", "").strip()
            broadcast = data.get("broadcast", "255.255.255.255").strip()
            if not mac:
                self._json(400, {"ok": False, "error": "Missing 'mac'"})
                return
            try:
                send_magic_packet(mac, broadcast)
                self._json(200, {"ok": True, "mac": mac, "broadcast": broadcast})
            except Exception as e:
                self._json(500, {"ok": False, "error": str(e)})
            return

        if parsed.path == "/wol/fritzbox":
            data = self._read_json()
            host = data.get("host", "fritz.box").strip()
            mac = data.get("mac", "").strip()
            user = data.get("user", "").strip()
            password = data.get("password", "").strip()
            if not mac:
                self._json(400, {"ok": False, "error": "Missing 'mac'"})
                return
            result = fritzbox_wol(host, mac, user, password)
            self._json(200 if result.get("ok") else 502, result)
            return

        self._json(404, {"ok": False, "error": "Not found"})


# ── Main ──────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", PORT), Handler)
    print(f"[wol-proxy] Listening on http://127.0.0.1:{PORT}")
    print(f"[wol-proxy] CORS origin: {CORS_ORIGIN}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[wol-proxy] Stopped.")
