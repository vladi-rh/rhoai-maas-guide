#!/usr/bin/env python3
"""Agent console — serves the control UI and proxies to each agent's control API.

Runs in-cluster so the browser talks to one Route instead of N port-forwards.
Agent endpoints are reached over cluster DNS (<agent>.<namespace>.svc:8080).

    GET  /                        -> index.html
    GET  /api/agents              -> registry (id, group, namespace, colour)
    GET  /api/status              -> fan-out snapshot of every agent + totals
    POST /api/start|stop|reset    -> broadcast to every agent
    POST /api/agents/<id>/start|stop|reset
    GET  /healthz

AGENTS env var holds the registry as JSON, written by provision-console.sh.
"""

import json
import os
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "8080"))
STATIC_DIR = os.environ.get("STATIC_DIR", "/opt/console")
AGENT_TIMEOUT = float(os.environ.get("AGENT_TIMEOUT", "5"))

AGENTS = json.loads(os.environ.get("AGENTS", "[]"))
BY_ID = {a["id"]: a for a in AGENTS}

# Dracula palette — must match shared.sh's D_CYAN / D_GREEN / D_PURPLE so the
# UI and the colour-coded log tail in follow-agents.sh agree.
GROUP_COLORS = {
    "chatbots": "#8BE9FD",
    "code-reviewers": "#50FA7B",
    "business-analysts": "#BD93F9",
}
DEFAULT_COLOR = "#FFB86C"

POOL = ThreadPoolExecutor(max_workers=max(4, len(AGENTS) * 2))


def agent_color(group):
    return GROUP_COLORS.get(group, DEFAULT_COLOR)


def call_agent(agent, path, method="GET", payload=None):
    """One request to one agent's control API. Never raises — unreachable is a state."""
    url = f"{agent['url'].rstrip('/')}{path}"
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=AGENT_TIMEOUT) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        return {"agent_id": agent["id"], "state": "error",
                "reachable": False, "error": f"HTTP {e.code}"}
    except Exception as e:
        return {"agent_id": agent["id"], "state": "unreachable",
                "reachable": False, "error": str(e)}


def decorate(agent, result):
    """Merge registry metadata into an agent's own status payload."""
    out = dict(result)
    out.setdefault("agent_id", agent["id"])
    out.setdefault("group", agent["group"])
    out["namespace"] = agent["namespace"]
    out["color"] = agent_color(agent["group"])
    out.setdefault("reachable", True)
    out.setdefault("running", out.get("state") == "running")
    return out


def fan_out(path, method="GET", payload=None, only=None):
    targets = [BY_ID[only]] if only else AGENTS
    results = list(POOL.map(lambda a: decorate(a, call_agent(a, path, method, payload)), targets))
    results.sort(key=lambda r: r["agent_id"])
    return results


def totals(results):
    acc = {"requests": 0, "ok": 0, "client_err": 0, "server_err": 0,
           "net_err": 0, "errors": 0, "tokens": 0}
    running = 0
    reachable = 0
    for r in results:
        if not r.get("reachable"):
            continue
        reachable += 1
        running += 1 if r.get("running") else 0
        for k in acc:
            acc[k] += r.get(k) or 0
    scored = acc["ok"] + acc["errors"]
    acc["success_ratio"] = round(acc["ok"] / scored, 4) if scored else None
    acc["agents_running"] = running
    acc["agents_reachable"] = reachable
    acc["agents_total"] = len(results)
    return acc


class ConsoleHandler(BaseHTTPRequestHandler):
    server_version = "maas-agent-console/1.0"

    def log_message(self, *_args):
        pass

    def _json(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _static(self, filename, content_type):
        path = os.path.join(STATIC_DIR, filename)
        try:
            with open(path, "rb") as f:
                body = f.read()
        except OSError:
            self._json(404, {"error": f"{filename} not found"})
            return
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0].rstrip("/")
        if path in ("", "/index.html"):
            self._static("index.html", "text/html; charset=utf-8")
        elif path == "/healthz":
            self._json(200, {"ok": True, "agents": len(AGENTS)})
        elif path == "/api/agents":
            self._json(200, [{"id": a["id"], "group": a["group"],
                              "namespace": a["namespace"],
                              "color": agent_color(a["group"])} for a in AGENTS])
        elif path == "/api/status":
            results = fan_out("/status")
            self._json(200, {"agents": results, "totals": totals(results)})
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):
        path = self.path.split("?")[0].rstrip("/")
        try:
            length = int(self.headers.get("Content-Length") or 0)
            payload = json.loads(self.rfile.read(length)) if length else {}
        except Exception:
            payload = {}

        parts = [p for p in path.split("/") if p]
        # /api/<action>  or  /api/agents/<id>/<action>
        if len(parts) == 2 and parts[0] == "api" and parts[1] in ("start", "stop", "reset"):
            target, action = None, parts[1]
        elif len(parts) == 4 and parts[:2] == ["api", "agents"] and parts[3] in ("start", "stop", "reset"):
            target, action = parts[2], parts[3]
            if target not in BY_ID:
                self._json(404, {"error": f"unknown agent: {target}"})
                return
        else:
            self._json(404, {"error": "not found"})
            return

        results = fan_out(f"/{action}", method="POST", payload=payload, only=target)
        self._json(200, {"agents": results, "totals": totals(results)})


def main():
    if not AGENTS:
        print("WARNING: AGENTS registry is empty — nothing to control", flush=True)
    httpd = ThreadingHTTPServer(("0.0.0.0", PORT), ConsoleHandler)
    httpd.daemon_threads = True
    print(f"Agent console on :{PORT} — {len(AGENTS)} agent(s): "
          f"{', '.join(a['id'] for a in AGENTS)}", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
