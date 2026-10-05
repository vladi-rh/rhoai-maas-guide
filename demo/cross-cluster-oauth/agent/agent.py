#!/usr/bin/env python3
"""MaaS agent simulator — authenticates via Keycloak client-credentials, calls LLM inference.

The pod stays up permanently and idles until told to work. A small HTTP control
plane on CONTROL_PORT lets the agent console start/stop traffic and read counters
without a pod restart (which would re-mint the JWT and API key, and lose counters):

    GET  /status   -> JSON state + counters
    POST /start    -> body {"cycles": N, "reset": bool} (both optional)
    POST /stop
    POST /reset    -> zero the counters
    GET  /healthz
"""

import json
import os
import random
import signal
import ssl
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

AGENT_ID = os.environ.get("CLIENT_ID", "unknown-agent")
AGENT_GROUP = os.environ.get("AGENT_GROUP", "unknown")
KEYCLOAK_TOKEN_ENDPOINT = os.environ["KEYCLOAK_TOKEN_ENDPOINT"]
CLIENT_ID = os.environ["CLIENT_ID"]
CLIENT_SECRET = os.environ["CLIENT_SECRET"]
MAAS_URL = os.environ["MAAS_URL"].rstrip("/")
MODEL_NAME = os.environ.get("MODEL_NAME", "facebook/opt-125m")          # HuggingFace model ID — used in request body
MODEL_PATH = os.environ.get("MODEL_PATH", "facebook-opt-125m-simulated")  # K8s resource name — used in URL path
PROFILE_PATH = os.environ.get("PROFILE_PATH", "/etc/agent/profile.yaml")
CONTROL_PORT = int(os.environ.get("CONTROL_PORT", "8080"))
DEFAULT_CYCLES = int(os.environ.get("MAX_CYCLES", "0"))  # 0 = run until stopped
AUTOSTART = os.environ.get("AUTOSTART", "false").lower() in ("1", "true", "yes")

SSL_CTX = ssl.create_default_context()
SSL_CTX.check_hostname = False
SSL_CTX.verify_mode = ssl.CERT_NONE

BOOT_TIME = time.time()

_shutdown_flag = threading.Event()   # set once on SIGTERM/SIGINT — terminal
_run_flag = threading.Event()        # set while the agent should be sending traffic

_OK  = '\033[0;92m'   # bright green for 200
_ERR = '\033[0;91m'   # bright red for non-200
_RST = '\033[0m'


def status_str(code):
    c = _OK if 200 <= code < 300 else _ERR
    return f"{c}[{code}]{_RST}"


def log(msg):
    ts = datetime.utcnow().strftime("%H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)


def working():
    """True while the agent should keep sending traffic."""
    return _run_flag.is_set() and not _shutdown_flag.is_set()


def load_profile(path):
    profile = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if ":" not in line:
                continue
            key, val = line.split(":", 1)
            key = key.strip()
            val = val.strip().strip('"').strip("'")
            try:
                val = int(val)
            except ValueError:
                try:
                    val = float(val)
                except ValueError:
                    pass
            profile[key] = val
    return profile


class Stats:
    """Request counters. Cumulative since pod start (or since the last explicit reset)."""

    def __init__(self):
        self._lock = threading.Lock()
        self.reset()

    def reset(self):
        with self._lock:
            self.requests = 0
            self.ok = 0            # 2xx
            self.client_err = 0    # 4xx
            self.server_err = 0    # 5xx
            self.net_err = 0       # transport failure, no HTTP status
            self.tokens = 0
            self.cycles = 0
            self.last_status = None
            self.last_latency_ms = None
            self.run_seconds = 0.0
            self._run_started = None

    def record(self, status, elapsed, tokens):
        with self._lock:
            self.requests += 1
            if 200 <= status < 300:
                self.ok += 1
            elif 400 <= status < 500:
                self.client_err += 1
            elif status >= 500:
                self.server_err += 1
            else:
                self.net_err += 1
            if isinstance(tokens, int):
                self.tokens += tokens
            self.last_status = status
            self.last_latency_ms = round(elapsed * 1000)

    def cycle_done(self):
        with self._lock:
            self.cycles += 1

    def mark_running(self):
        with self._lock:
            if self._run_started is None:
                self._run_started = time.time()

    def mark_stopped(self):
        with self._lock:
            if self._run_started is not None:
                self.run_seconds += time.time() - self._run_started
                self._run_started = None

    def snapshot(self):
        with self._lock:
            run_seconds = self.run_seconds
            if self._run_started is not None:
                run_seconds += time.time() - self._run_started
            errors = self.client_err + self.server_err + self.net_err
            total = self.ok + errors
            return {
                "requests": self.requests,
                "ok": self.ok,
                "client_err": self.client_err,
                "server_err": self.server_err,
                "net_err": self.net_err,
                "errors": errors,
                "tokens": self.tokens,
                "cycles": self.cycles,
                "success_ratio": round(self.ok / total, 4) if total else None,
                "last_status": self.last_status,
                "last_latency_ms": self.last_latency_ms,
                "run_seconds": round(run_seconds, 1),
            }


STATS = Stats()


class ApiKeyManager:
    """Mints a MaaS API key using the JWT, caches it, refreshes before expiry."""

    KEY_TTL_SECONDS = 3600  # 1 hour

    def __init__(self, token_manager):
        self._tm = token_manager
        self._key = None
        self._expires_at = 0
        self._lock = threading.Lock()

    def get_key(self):
        with self._lock:
            if self._key and time.time() < self._expires_at:
                return self._key
            return self._refresh()

    def _refresh(self):
        jwt = self._tm.get_token()
        payload = json.dumps({
            "name": f"agent-{AGENT_ID}-{int(time.time())}",
            "description": f"Auto-minted by {AGENT_ID}",
            "expiresIn": f"{self.KEY_TTL_SECONDS}s",
        }).encode()
        req = urllib.request.Request(
            f"{MAAS_URL}/maas-api/v1/api-keys",
            data=payload,
            headers={
                "Authorization": f"Bearer {jwt}",
                "Content-Type": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(req, context=SSL_CTX, timeout=15) as resp:
                body = json.loads(resp.read())
            self._key = body["key"]
            self._expires_at = time.time() + self.KEY_TTL_SECONDS - 60
            log(f"🎫 {status_str(201)} API key minted (expires in {self.KEY_TTL_SECONDS}s)")
            return self._key
        except urllib.error.HTTPError as e:
            log(f"🎫 {status_str(e.code)} API key mint failed: {e.reason}")
            raise
        except Exception as e:
            log(f"🎫 {status_str(0)} API key mint error: {e}")
            raise


class TokenManager:
    def __init__(self):
        self._token = None
        self._expires_at = 0
        self._lock = threading.Lock()
        self.last_claims = {}

    def get_token(self):
        with self._lock:
            if self._token and time.time() < self._expires_at:
                return self._token
            return self._refresh()

    def _refresh(self):
        params = {
            "grant_type": "client_credentials",
            "client_id": CLIENT_ID,
            "client_secret": CLIENT_SECRET,
        }
        data = urllib.parse.urlencode(params).encode()
        req = urllib.request.Request(KEYCLOAK_TOKEN_ENDPOINT, data=data,
                                     headers={"Content-Type": "application/x-www-form-urlencoded"})
        try:
            with urllib.request.urlopen(req, context=SSL_CTX, timeout=15) as resp:
                body = json.loads(resp.read())
            self._token = body["access_token"]
            expires_in = body.get("expires_in", 300)
            self._expires_at = time.time() + expires_in - 30
            # Decode and log key JWT claims
            try:
                import base64
                payload = self._token.split(".")[1]
                payload += "=" * (4 - len(payload) % 4)
                claims = json.loads(base64.urlsafe_b64decode(payload))
                exp_ts = claims.get('exp')
                exp_str = datetime.utcfromtimestamp(exp_ts).strftime('%H:%M:%S UTC') if exp_ts else '?'
                self.last_claims = {"groups": claims.get("groups", []), "exp": exp_ts}
                log(f"🔑 {status_str(200)} groups={claims.get('groups',[])} iss={claims.get('iss','').split('/')[-1]} exp={exp_str}")
            except Exception:
                log(f"🔑 {status_str(200)} token minted (expires_in={expires_in}s)")
            return self._token
        except urllib.error.HTTPError as e:
            log(f"🔑 {status_str(e.code)} token mint failed: {e.reason}")
            raise
        except Exception as e:
            log(f"🔑 {status_str(0)} token mint error: {e}")
            raise


def call_inference(api_key, prompt, model=MODEL_NAME, path=MODEL_PATH):
    endpoint = f"{MAAS_URL}/llm/{path}/v1/chat/completions"
    payload = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": 50,
    }).encode()
    req = urllib.request.Request(
        endpoint,
        data=payload,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
    )
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, context=SSL_CTX, timeout=30) as resp:
            body = json.loads(resp.read())
            elapsed = time.time() - t0
            tokens = body.get("usage", {}).get("total_tokens", 0)
            return 200, elapsed, tokens
    except urllib.error.HTTPError as e:
        elapsed = time.time() - t0
        return e.code, elapsed, 0
    except Exception as e:
        elapsed = time.time() - t0
        log(f"💬 request error: {e}")
        return 0, elapsed, 0


def send(keys, prompt, model, label):
    """One inference call: mint/reuse key, record the result, log it."""
    try:
        api_key = keys.get_key()
    except Exception:
        STATS.record(0, 0.0, 0)
        _interruptible_sleep(5)
        return
    status, elapsed, tok_count = call_inference(api_key, prompt, model)
    STATS.record(status, elapsed, tok_count)
    log(f"💬 {status_str(status)} {elapsed:.2f}s | {label} | tokens: {tok_count}")


def run_conversational(profile, keys, model, max_cycles):
    think_min = profile.get("thinkTimeMinSec", 3)
    think_max = profile.get("thinkTimeMaxSec", 8)
    prompt = profile.get("promptTemplate", "Hello, how can you help me today?")
    cycle = 0

    while working():
        if max_cycles and cycle >= max_cycles:
            log(f"Completed {max_cycles} cycles — stopping")
            return
        send(keys, prompt, model, "conversational")
        cycle += 1
        STATS.cycle_done()
        _interruptible_sleep(random.uniform(think_min, think_max))


def run_burst(profile, keys, model, max_cycles):
    think_min = profile.get("thinkTimeMinSec", 10)
    think_max = profile.get("thinkTimeMaxSec", 30)
    burst_min = profile.get("burstSizeMin", 3)
    burst_max = profile.get("burstSizeMax", 5)
    prompt = profile.get("promptTemplate", "Review this code for issues.")
    cycle = 0

    while working():
        if max_cycles and cycle >= max_cycles:
            log(f"Completed {max_cycles} cycles — stopping")
            return
        burst_size = random.randint(burst_min, burst_max)
        log(f"Sending burst of {burst_size} requests")
        for i in range(burst_size):
            if not working():
                return
            send(keys, prompt, model, f"burst {i+1}/{burst_size}")
        cycle += 1
        STATS.cycle_done()
        sleep_for = random.uniform(think_min, think_max)
        log(f"Burst complete, pausing {sleep_for:.0f}s")
        _interruptible_sleep(sleep_for)


def run_periodic(profile, keys, model, max_cycles):
    burst_min = profile.get("burstSizeMin", 5)
    burst_max = profile.get("burstSizeMax", 10)
    think_min = profile.get("thinkTimeMinSec", 1)
    think_max = profile.get("thinkTimeMaxSec", 3)
    pause = profile.get("pauseAfterBurstSec", 30)
    prompt = profile.get("promptTemplate", "Analyze this data point.")
    cycle = 0

    while working():
        if max_cycles and cycle >= max_cycles:
            log(f"Completed {max_cycles} cycles — stopping")
            return
        burst_size = random.randint(burst_min, burst_max)
        log(f"Sending periodic burst of {burst_size} requests")
        for i in range(burst_size):
            if not working():
                return
            send(keys, prompt, model, f"periodic {i+1}/{burst_size}")
            if i < burst_size - 1:
                _interruptible_sleep(random.uniform(think_min, think_max))
        cycle += 1
        STATS.cycle_done()
        log(f"Periodic burst complete, long pause {pause}s")
        _interruptible_sleep(pause)


def _interruptible_sleep(seconds):
    """Sleep, but wake immediately on /stop or SIGTERM."""
    end = time.time() + seconds
    while working() and time.time() < end:
        time.sleep(min(0.5, max(0.0, end - time.time())))


def _shutdown(signum, _frame):
    _shutdown_flag.set()
    _run_flag.set()  # unblock the worker's wait() so it can see the shutdown flag


PATTERNS = {
    "conversational": run_conversational,
    "burst": run_burst,
    "periodic": run_periodic,
}


class Worker(threading.Thread):
    """Parks on _run_flag; runs the profile's traffic pattern while it is set."""

    def __init__(self, profile, keys, model):
        super().__init__(daemon=True)
        self.profile = profile
        self.keys = keys
        self.model = model
        self.pattern = profile.get("pattern", "conversational")
        self.cycles = DEFAULT_CYCLES
        self.state = "idle"   # idle | running | completed

    def run(self):
        runner = PATTERNS[self.pattern]
        while not _shutdown_flag.is_set():
            _run_flag.wait()
            if _shutdown_flag.is_set():
                break
            self.state = "running"
            STATS.mark_running()
            limit = "unlimited" if not self.cycles else f"{self.cycles} cycle(s)"
            log(f"▶ started — pattern={self.pattern}, {limit}")
            try:
                runner(self.profile, self.keys, self.model, self.cycles)
            except Exception as e:
                log(f"⚠ pattern error: {e}")
            STATS.mark_stopped()
            # Distinguish "ran out of cycles" from "operator pressed stop"
            self.state = "completed" if _run_flag.is_set() else "idle"
            if self.state == "completed":
                log("⏹ done — idling")
                _run_flag.clear()
            else:
                log("⏹ stopped — idling")


class ControlHandler(BaseHTTPRequestHandler):
    server_version = "maas-agent/1.0"
    worker = None   # set in main()

    def log_message(self, *_args):
        pass  # keep the pod log to agent traffic only

    def _send(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        try:
            length = int(self.headers.get("Content-Length") or 0)
            return json.loads(self.rfile.read(length)) if length else {}
        except Exception:
            return {}

    def _status(self):
        w = self.worker
        # _run_flag is the authority on intent; worker.state lags it by up to one
        # in-flight request, so surface the transition rather than a stale answer.
        wanted = _run_flag.is_set()
        state = w.state
        if wanted and state != "running":
            state = "starting"
        elif not wanted and state == "running":
            state = "stopping"
        snap = STATS.snapshot()
        snap.update({
            "agent_id": AGENT_ID,
            "group": AGENT_GROUP,
            "pattern": w.pattern,
            "model": w.model,
            "state": state,
            "running": wanted,
            "cycles_limit": w.cycles,
            "uptime_seconds": round(time.time() - BOOT_TIME, 1),
        })
        return snap

    def do_GET(self):
        if self.path.rstrip("/") in ("/status", ""):
            self._send(200, self._status())
        elif self.path.rstrip("/") == "/healthz":
            self._send(200, {"ok": True})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        path = self.path.rstrip("/")
        body = self._body()
        if path == "/start":
            if body.get("reset"):
                STATS.reset()
            cycles = body.get("cycles")
            if cycles is not None:
                try:
                    self.worker.cycles = max(0, int(cycles))
                except (TypeError, ValueError):
                    self._send(400, {"error": "cycles must be an integer"})
                    return
            _run_flag.set()
            self._send(200, self._status())
        elif path == "/stop":
            _run_flag.clear()
            self._send(200, self._status())
        elif path == "/reset":
            STATS.reset()
            if self.worker.state == "running":
                STATS.mark_running()
            self._send(200, self._status())
        else:
            self._send(404, {"error": "not found"})


def demo_once():
    """Mint JWT → mint API key → one inference call. Used by run-demo.sh."""
    profile = load_profile(PROFILE_PATH)
    model = profile.get("model", MODEL_NAME)
    prompt = profile.get("promptTemplate", "Hello, what can you help me with?")
    tm = TokenManager()
    keys = ApiKeyManager(tm)
    for attempt in range(3):
        try:
            api_key = keys.get_key()
            break
        except urllib.error.HTTPError as e:
            log(f"\U0001f3ab {status_str(e.code)} API key mint failed — retry {attempt + 1}/3")
            if attempt == 2:
                raise
            time.sleep(3)
    status, elapsed, tok_count = call_inference(api_key, prompt, model)
    log(f"demo-once complete | status={status} elapsed={elapsed:.2f}s tokens={tok_count}")


def premint(keys):
    """Warm the JWT + API key at boot so the first /start is instant."""
    while not _shutdown_flag.is_set():
        try:
            keys.get_key()
            return
        except urllib.error.HTTPError as e:
            log(f"🎫 {status_str(e.code)} API key mint failed — retrying in 30s")
        except Exception as e:
            log(f"🎫 {status_str(0)} API key mint error ({e}) — retrying in 30s")
        _shutdown_flag.wait(30)


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--demo":
        demo_once()
        return

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    profile = load_profile(PROFILE_PATH)
    pattern = profile.get("pattern", "conversational")
    model = profile.get("model", MODEL_NAME)

    if pattern not in PATTERNS:
        log(f"Unknown pattern: {pattern}")
        sys.exit(1)

    tm = TokenManager()
    keys = ApiKeyManager(tm)
    threading.Thread(target=premint, args=(keys,), daemon=True).start()

    worker = Worker(profile, keys, model)
    worker.start()

    ControlHandler.worker = worker
    httpd = ThreadingHTTPServer(("0.0.0.0", CONTROL_PORT), ControlHandler)
    httpd.daemon_threads = True
    log(f"Agent {AGENT_ID} ready (model={model}, pattern={pattern}) — control API on :{CONTROL_PORT}")

    if AUTOSTART:
        _run_flag.set()

    threading.Thread(target=httpd.serve_forever, daemon=True).start()

    while not _shutdown_flag.is_set():
        _shutdown_flag.wait(1)

    log("Shutting down")
    httpd.shutdown()


if __name__ == "__main__":
    main()
