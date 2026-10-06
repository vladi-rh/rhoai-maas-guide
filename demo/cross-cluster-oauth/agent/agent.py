#!/usr/bin/env python3
"""MaaS agent simulator — authenticates via Keycloak client-credentials, calls LLM inference.

The pod stays up permanently and idles until told to work. A small HTTP control
plane on CONTROL_PORT lets the agent console start/stop traffic and read counters
without a pod restart (which would re-mint the JWT and API key, and lose counters):

    GET  /status   -> JSON state + counters
    POST /start    -> body {"reset": bool} (optional); runs until /stop
    POST /stop
    POST /reset    -> zero the counters
    GET  /logs     -> {"lines": [...], "seq": n}; ?since=<seq> for the tail only
    GET  /healthz
"""

import collections
import json
import os
import re
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
AUTOSTART = os.environ.get("AUTOSTART", "false").lower() in ("1", "true", "yes")
# Lifetime of the minted MaaS API key. This value is advisory: maas-api honours whatever the
# client asks for, exactly, with no floor (request 1s and you get 1s). The only server-ENFORCED
# bound is the tenant's MaasTenantConfig maxExpirationDays, which provision-infra.sh pins to
# 1 day for the agents tenant. Shorter means a shorter revocation tail and faster detection of
# a broken mint path, at the cost of riding out an upstream outage for less time.
# Per-group overrides live in profiles/*.yaml as keyTtlSeconds.
KEY_TTL_SECONDS = max(10, int(os.environ.get("KEY_TTL_SECONDS", "300")))

# Reacting to a revoked key.
#
# The key cache is refreshed on time alone, so without this a revoked key is
# retried until its TTL runs out -- ten minutes of 403s for a 600s reviewer.
# 401/403 now drop the cached key and re-mint once, which recovers on the very
# next request: a new key is a new entry in the gateway's auth cache, so the
# 60s TTL on the old decision does not delay it.
#
# 429 is deliberately NOT in this set. Rate limits are counted per subscription,
# not per key, so minting a replacement cannot help -- it would just burn rows.
AUTH_FAIL_STATUSES = (401, 403)

# ... and the guard against that recovery becoming a mint storm. A 403 does not
# only mean "revoked"; if the cause is persistent (a policy denial, a disabled
# subscription) an unguarded re-mint would issue a brand-new key on every single
# request. Nothing prunes expired keys -- the cleanup CronJob only deletes rows
# with ephemeral=true, which nothing here sets -- so that turns a slow leak into
# a flood. After this many consecutive failures the agent stops calling instead.
AUTH_FAIL_THRESHOLD = max(1, int(os.environ.get("AUTH_FAIL_THRESHOLD", "3")))

# Escalating, so a permanently dead agent backs off instead of polling forever:
# 30s, 60s, 120s, 240s, capped. Any success resets it.
AUTH_COOLDOWN_BASE = max(5, int(os.environ.get("AUTH_COOLDOWN_BASE", "30")))
AUTH_COOLDOWN_MAX = max(AUTH_COOLDOWN_BASE, int(os.environ.get("AUTH_COOLDOWN_MAX", "300")))

# Deliberate pause between the rejected call and the retry, for legibility.
#
# Recovery is otherwise so fast (~1s) that it hides itself: the console polls
# every 2s, so last_status flips 403 -> 200 between two polls and an observer
# sees nothing happen at all. Holding the rejected status for longer than one
# poll interval makes the 403 land in the UI, in red, before the recovery
# clears it — the fix is more convincing when you can see what it fixed.
#
# Set to 0 for production-like behaviour, where the extra latency buys nothing.
AUTH_RETRY_PAUSE_S = max(0.0, float(os.environ.get("AUTH_RETRY_PAUSE_S", "2.5")))

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


_ANSI = re.compile(r"\033\[[0-9;]*m")


class LogBuffer:
    """Last N log lines, so the console can tail an agent without Kubernetes API access.

    Every line gets a monotonic seq; clients poll with ?since=<seq> and get only what
    is new. Stored stripped of ANSI colour (the UI applies its own); stdout keeps the
    colour so `oc logs` / follow-agents.sh look unchanged.
    """

    MAX_LINES = 500

    def __init__(self):
        self._lock = threading.Lock()
        self._lines = collections.deque(maxlen=self.MAX_LINES)
        self._seq = 0

    def add(self, ts, msg):
        with self._lock:
            self._seq += 1
            self._lines.append({"seq": self._seq, "t": time.time(),
                                "ts": ts, "msg": _ANSI.sub("", msg)})

    def since(self, seq):
        with self._lock:
            # A cursor beyond our own sequence means the client is ahead of us, i.e. this
            # pod restarted and began numbering from 1 again. Treat it as a fresh start and
            # replay the buffer, otherwise the console would silently skip the restart's
            # own startup lines until the new pod caught back up to the stale cursor.
            if seq > self._seq:
                seq = 0
            return [l for l in self._lines if l["seq"] > seq], self._seq


LOGS = LogBuffer()


def log(msg):
    ts = datetime.utcnow().strftime("%H:%M:%S")
    LOGS.add(ts, msg)
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
                "success_ratio": round(self.ok / total, 4) if total else None,
                "last_status": self.last_status,
                "last_latency_ms": self.last_latency_ms,
                "run_seconds": round(run_seconds, 1),
            }


STATS = Stats()


def token_info(fetched_at, expires_at, error):
    """Age and remaining validity of a credential, in seconds, as of right now.

    Computed here rather than sent as raw epochs so the UI never has to reconcile the
    browser's clock with the pod's.
    """
    now = time.time()
    return {
        "fetched_at": fetched_at,
        "age_s": round(now - fetched_at, 1) if fetched_at else None,
        "ttl_s": round(expires_at - now, 1) if expires_at else None,
        "error": error,
    }


class ApiKeyManager:
    """Mints a MaaS API key using the JWT, caches it, refreshes before expiry."""

    def __init__(self, token_manager, ttl_seconds=None):
        self._tm = token_manager
        self._key = None
        self._expires_at = 0        # refresh deadline (expiry minus a safety margin)
        self._lock = threading.Lock()

        # Precedence: profile keyTtlSeconds > KEY_TTL_SECONDS env > built-in default.
        # Per-group TTLs let each workload shape carry its own credential lifetime.
        try:
            self.ttl_seconds = max(10, int(ttl_seconds)) if ttl_seconds else KEY_TTL_SECONDS
        except (TypeError, ValueError):
            log(f"⚠ invalid keyTtlSeconds={ttl_seconds!r}, falling back to {KEY_TTL_SECONDS}s")
            self.ttl_seconds = KEY_TTL_SECONDS

        # Refresh this long before expiry. Proportional, not a flat 60s: a fixed margin
        # inverts once the TTL drops to 60 or below (_expires_at lands in the past),
        # making get_key() miss the cache on every call and mint a key per request.
        # 10% reproduces the old behaviour at a 3600s TTL while staying safe when short.
        self.refresh_margin = max(5, min(60, int(self.ttl_seconds * 0.1)))
        # Surfaced on /status so the console can show token health per agent.
        self.fetched_at = None      # epoch of the last successful mint
        self.hard_expires_at = None # epoch the key actually stops being valid
        self.last_error = None
        self.auth_failures = 0      # consecutive 401/403 that survived a re-mint
        self.cooldown_until = 0     # epoch; agent makes no calls before this
        self.last_auth_error = None
        self.rejections = 0         # cumulative keys rejected out from under us

    def get_key(self):
        with self._lock:
            if self._key and time.time() < self._expires_at:
                return self._key
            return self._refresh()

    def invalidate(self, reason):
        """Drop the cached key so the next get_key() mints a replacement.

        Called when the gateway rejects the key we hold -- the only path that
        refreshes on something other than the clock.
        """
        with self._lock:
            if self._key:
                log(f"🎫 key rejected ({reason}) — discarding and re-minting")
                # Cumulative, and never reset by a success: auth_failures is
                # cleared the moment the agent recovers, so it cannot answer
                # "has this agent been revoked out from under it?" after the
                # fact. This is what the console's counter reads.
                self.rejections += 1
            self._key = None
            self._expires_at = 0
            # Clear the expiry too, not just the cached key. hard_expires_at is
            # what the console renders as "valid XmYs", so leaving it set means
            # the UI keeps counting down a key the gateway has already refused
            # — the most misleading thing on the card at exactly the moment
            # someone is looking at it. last_error replaces the countdown until
            # _refresh() succeeds and clears it.
            self.hard_expires_at = None
            self.fetched_at = None
            # One word. The console renders this as "failed · <error>" in a
            # narrow column, and anything longer wrapped the row onto two lines.
            self.last_error = "revoked"

    def note_auth_failure(self, reason):
        """A re-minted key was rejected too. Count it, and back off at the threshold."""
        with self._lock:
            self.auth_failures += 1
            self.last_auth_error = reason
            if self.auth_failures < AUTH_FAIL_THRESHOLD:
                return 0
            # 1st trip 30s, then 60, 120, 240, capped. Counting from the
            # threshold means the first cooldown is always the base.
            step = self.auth_failures - AUTH_FAIL_THRESHOLD
            backoff = min(AUTH_COOLDOWN_BASE * (2 ** step), AUTH_COOLDOWN_MAX)
            self.cooldown_until = time.time() + backoff
            log(f"⏸ {self.auth_failures} consecutive auth failures ({reason}) — "
                f"pausing {backoff}s before trying again")
            return backoff

    def note_success(self):
        with self._lock:
            if self.auth_failures:
                log(f"▶ recovered after {self.auth_failures} auth failure(s)")
            self.auth_failures = 0
            self.cooldown_until = 0
            self.last_auth_error = None

    def cooldown_remaining(self):
        return max(0.0, self.cooldown_until - time.time())

    def _refresh(self):
        jwt = self._tm.get_token()
        payload = json.dumps({
            "name": f"agent-{AGENT_ID}-{int(time.time())}",
            "description": f"Auto-minted by {AGENT_ID}",
            "expiresIn": f"{self.ttl_seconds}s",
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
            now = time.time()
            self._expires_at = now + self.ttl_seconds - self.refresh_margin
            self.fetched_at = now
            self.hard_expires_at = now + self.ttl_seconds
            self.last_error = None
            log(f"🎫 {status_str(201)} API key minted "
                f"(expires in {self.ttl_seconds}s, refresh at -{self.refresh_margin}s)")
            return self._key
        except urllib.error.HTTPError as e:
            self.last_error = f"HTTP {e.code}"
            log(f"🎫 {status_str(e.code)} API key mint failed: {e.reason}")
            raise
        except Exception as e:
            self.last_error = str(e)[:80]
            log(f"🎫 {status_str(0)} API key mint error: {e}")
            raise

    def info(self):
        """Age/TTL computed agent-side, so the browser's clock never matters."""
        out = token_info(self.fetched_at, self.hard_expires_at, self.last_error)
        # Surfaced so the console can show "paused, retrying in Ns" rather than
        # an agent that merely looks idle for no stated reason.
        out["auth_failures"] = self.auth_failures
        out["cooldown_s"] = round(self.cooldown_remaining(), 1) or None
        out["auth_error"] = self.last_auth_error
        out["rejections"] = self.rejections
        return out


class TokenManager:
    def __init__(self):
        self._token = None
        self._expires_at = 0        # refresh deadline (expiry minus a safety margin)
        self._lock = threading.Lock()
        self.last_claims = {}
        self.fetched_at = None      # epoch of the last successful mint
        self.hard_expires_at = None # epoch from the JWT's own exp claim
        self.last_error = None

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
            now = time.time()
            self._expires_at = now + expires_in - 30
            self.fetched_at = now
            # Overwritten below with the JWT's own exp claim when it decodes.
            self.hard_expires_at = now + expires_in
            self.last_error = None
            # Decode and log key JWT claims
            try:
                import base64
                payload = self._token.split(".")[1]
                payload += "=" * (4 - len(payload) % 4)
                claims = json.loads(base64.urlsafe_b64decode(payload))
                exp_ts = claims.get('exp')
                exp_str = datetime.utcfromtimestamp(exp_ts).strftime('%H:%M:%S UTC') if exp_ts else '?'
                self.last_claims = {"groups": claims.get("groups", []), "exp": exp_ts}
                if exp_ts:
                    self.hard_expires_at = float(exp_ts)
                log(f"🔑 {status_str(200)} groups={claims.get('groups',[])} iss={claims.get('iss','').split('/')[-1]} exp={exp_str}")
            except Exception:
                log(f"🔑 {status_str(200)} token minted (expires_in={expires_in}s)")
            return self._token
        except urllib.error.HTTPError as e:
            self.last_error = f"HTTP {e.code}"
            log(f"🔑 {status_str(e.code)} token mint failed: {e.reason}")
            raise
        except Exception as e:
            self.last_error = str(e)[:80]
            log(f"🔑 {status_str(0)} token mint error: {e}")
            raise

    def info(self):
        return token_info(self.fetched_at, self.hard_expires_at, self.last_error)


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
        # Carry the [0] marker here too, matching the token/key mint error lines, so the
        # reason text lands in the same filter bucket as the result line it belongs to.
        log(f"💬 {status_str(0)} request error: {e}")
        return 0, elapsed, 0


def _attempt(keys, prompt, model, label):
    """One inference call against the current key. Returns the HTTP status.

    Returns None if no key could be minted at all, which is a different failure
    from the gateway rejecting one and is counted as a transport error.
    """
    try:
        api_key = keys.get_key()
    except Exception:
        STATS.record(0, 0.0, 0)
        return None
    status, elapsed, tok_count = call_inference(api_key, prompt, model)
    STATS.record(status, elapsed, tok_count)
    log(f"💬 {status_str(status)} {elapsed:.2f}s | {label} | tokens: {tok_count}")
    return status


def send(keys, prompt, model, label):
    """One inference call, re-minting once if the gateway rejects the key.

    Both attempts are recorded in STATS: they are both real requests that the
    gateway saw, and hiding the first would make the console disagree with the
    gateway's own telemetry.
    """
    waiting = keys.cooldown_remaining()
    if waiting > 0:
        # Short sleeps rather than one long one, so /stop still responds promptly.
        _interruptible_sleep(min(waiting, 5))
        return

    status = _attempt(keys, prompt, model, label)
    if status is None:
        _interruptible_sleep(5)
        return

    if status not in AUTH_FAIL_STATUSES:
        if 200 <= status < 300:
            keys.note_success()
        return

    # The key we hold was rejected. It may simply have been revoked out from
    # under us, so discard it and try once with a fresh one -- but only once,
    # so a persistent denial cannot mint a key per request.
    keys.invalidate(f"HTTP {status}")
    # Pause before retrying so the 403 outlives a console poll — see
    # AUTH_RETRY_PAUSE_S. Interruptible, so /stop still responds immediately.
    if AUTH_RETRY_PAUSE_S:
        _interruptible_sleep(AUTH_RETRY_PAUSE_S)
    retry = _attempt(keys, prompt, model, label)
    if retry is None:
        keys.note_auth_failure("mint failed")
        _interruptible_sleep(5)
        return

    if retry in AUTH_FAIL_STATUSES:
        keys.note_auth_failure(f"HTTP {retry}")
    elif 200 <= retry < 300:
        keys.note_success()


def run_conversational(profile, keys, model):
    think_min = profile.get("thinkTimeMinSec", 3)
    think_max = profile.get("thinkTimeMaxSec", 8)
    prompt = profile.get("promptTemplate", "Hello, how can you help me today?")
    while working():
        send(keys, prompt, model, "conversational")
        _interruptible_sleep(random.uniform(think_min, think_max))


def run_burst(profile, keys, model):
    think_min = profile.get("thinkTimeMinSec", 10)
    think_max = profile.get("thinkTimeMaxSec", 30)
    burst_min = profile.get("burstSizeMin", 3)
    burst_max = profile.get("burstSizeMax", 5)
    prompt = profile.get("promptTemplate", "Review this code for issues.")
    while working():
        burst_size = random.randint(burst_min, burst_max)
        log(f"Sending burst of {burst_size} requests")
        for i in range(burst_size):
            if not working():
                return
            send(keys, prompt, model, f"burst {i+1}/{burst_size}")
        sleep_for = random.uniform(think_min, think_max)
        log(f"Burst complete, pausing {sleep_for:.0f}s")
        _interruptible_sleep(sleep_for)


def run_periodic(profile, keys, model):
    burst_min = profile.get("burstSizeMin", 5)
    burst_max = profile.get("burstSizeMax", 10)
    think_min = profile.get("thinkTimeMinSec", 1)
    think_max = profile.get("thinkTimeMaxSec", 3)
    pause = profile.get("pauseAfterBurstSec", 30)
    prompt = profile.get("promptTemplate", "Analyze this data point.")
    while working():
        burst_size = random.randint(burst_min, burst_max)
        log(f"Sending periodic burst of {burst_size} requests")
        for i in range(burst_size):
            if not working():
                return
            send(keys, prompt, model, f"periodic {i+1}/{burst_size}")
            if i < burst_size - 1:
                _interruptible_sleep(random.uniform(think_min, think_max))
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
        self.state = "idle"   # idle | running

    def run(self):
        # The runner only returns once working() goes false, i.e. /stop or SIGTERM.
        # There is no self-termination: an agent repeats its profile until told to stop.
        runner = PATTERNS[self.pattern]
        while not _shutdown_flag.is_set():
            _run_flag.wait()
            if _shutdown_flag.is_set():
                break
            self.state = "running"
            STATS.mark_running()
            log(f"▶ started — pattern={self.pattern}, running until stopped")
            try:
                runner(self.profile, self.keys, self.model)
            except Exception as e:
                log(f"⚠ pattern error: {e}")
            STATS.mark_stopped()
            self.state = "idle"
            log("⏹ stopped — idling")


class ControlHandler(BaseHTTPRequestHandler):
    server_version = "maas-agent/1.0"
    worker = None   # set in main()
    tokens = None   # TokenManager, set in main()
    keys = None     # ApiKeyManager, set in main()

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
            "jwt": self.tokens.info() if self.tokens else None,
            "api_key": self.keys.info() if self.keys else None,
            "key_ttl_seconds": self.keys.ttl_seconds if self.keys else None,
            "uptime_seconds": round(time.time() - BOOT_TIME, 1),
        })
        return snap

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip("/")
        qs = urllib.parse.parse_qs(parsed.query)
        if path in ("/status", ""):
            self._send(200, self._status())
        elif path == "/logs":
            try:
                since = int(qs.get("since", ["0"])[0])
            except (TypeError, ValueError):
                since = 0
            lines, seq = LOGS.since(since)
            self._send(200, {"agent_id": AGENT_ID, "group": AGENT_GROUP,
                             "seq": seq, "lines": lines})
        elif path == "/healthz":
            self._send(200, {"ok": True})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        path = self.path.rstrip("/")
        body = self._body()
        if path == "/start":
            if body.get("reset"):
                STATS.reset()
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
    keys = ApiKeyManager(tm, profile.get("keyTtlSeconds"))
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
    keys = ApiKeyManager(tm, profile.get("keyTtlSeconds"))
    threading.Thread(target=premint, args=(keys,), daemon=True).start()

    worker = Worker(profile, keys, model)
    worker.start()

    ControlHandler.worker = worker
    ControlHandler.tokens = tm
    ControlHandler.keys = keys
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
