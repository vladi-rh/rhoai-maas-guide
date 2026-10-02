#!/usr/bin/env python3
"""MaaS agent simulator — authenticates via Keycloak client-credentials, calls LLM inference."""

import json
import os
import random
import signal
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime

AGENT_ID = os.environ.get("CLIENT_ID", "unknown-agent")
KEYCLOAK_TOKEN_ENDPOINT = os.environ["KEYCLOAK_TOKEN_ENDPOINT"]
CLIENT_ID = os.environ["CLIENT_ID"]
CLIENT_SECRET = os.environ["CLIENT_SECRET"]
MAAS_URL = os.environ["MAAS_URL"].rstrip("/")
MODEL_NAME = os.environ.get("MODEL_NAME", "facebook/opt-125m")          # HuggingFace model ID — used in request body
MODEL_PATH = os.environ.get("MODEL_PATH", "facebook-opt-125m-simulated")  # K8s resource name — used in URL path
PROFILE_PATH = os.environ.get("PROFILE_PATH", "/etc/agent/profile.yaml")
MAX_CYCLES = int(os.environ.get("MAX_CYCLES", "0"))  # 0 = run forever

SSL_CTX = ssl.create_default_context()
SSL_CTX.check_hostname = False
SSL_CTX.verify_mode = ssl.CERT_NONE

_running = True
_OK  = '\033[0;92m'   # bright green for 200
_ERR = '\033[0;91m'   # bright red for non-200
_RST = '\033[0m'

def status_str(code):
    c = _OK if 200 <= code < 300 else _ERR
    return f"{c}[{code}]{_RST}"


def log(msg):
    ts = datetime.utcnow().strftime("%H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)


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



class ApiKeyManager:
    """Mints a MaaS API key using the JWT, caches it, refreshes before expiry."""

    KEY_TTL_SECONDS = 3600  # 1 hour

    def __init__(self, token_manager):
        self._tm = token_manager
        self._key = None
        self._expires_at = 0

    def get_key(self):
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

    def get_token(self):
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
            tokens = body.get("usage", {}).get("total_tokens", "?")
            return 200, elapsed, tokens
    except urllib.error.HTTPError as e:
        elapsed = time.time() - t0
        return e.code, elapsed, 0
    except Exception as e:
        elapsed = time.time() - t0
        log(f"💬 request error: {e}")
        return 0, elapsed, 0


def read_cycles(profile=None):
    return MAX_CYCLES


def run_conversational(profile, keys, model):
    think_min = profile.get("thinkTimeMinSec", 3)
    think_max = profile.get("thinkTimeMaxSec", 8)
    prompt = profile.get("promptTemplate", "Hello, how can you help me today?")
    max_cycles = read_cycles(profile)
    cycle = 0

    while _running:
        if max_cycles and cycle >= max_cycles:
            log(f"Completed {max_cycles} cycles — stopping")
            return
        token = keys.get_key()
        status, elapsed, tok_count = call_inference(token, prompt, model)
        log(f"💬 {status_str(status)} {elapsed:.2f}s | conversational | tokens: {tok_count}")
        cycle += 1
        if not _running:
            break
        sleep_for = random.uniform(think_min, think_max)
        _interruptible_sleep(sleep_for)


def run_burst(profile, keys, model):
    think_min = profile.get("thinkTimeMinSec", 10)
    think_max = profile.get("thinkTimeMaxSec", 30)
    burst_min = profile.get("burstSizeMin", 3)
    burst_max = profile.get("burstSizeMax", 5)
    prompt = profile.get("promptTemplate", "Review this code for issues.")
    max_cycles = read_cycles(profile)
    cycle = 0

    while _running:
        if max_cycles and cycle >= max_cycles:
            log(f"Completed {max_cycles} cycles — stopping")
            return
        burst_size = random.randint(burst_min, burst_max)
        log(f"Sending burst of {burst_size} requests")
        token = keys.get_key()
        for i in range(burst_size):
            if not _running:
                return
            status, elapsed, tok_count = call_inference(token, prompt, model)
            log(f"💬 {status_str(status)} {elapsed:.2f}s | burst {i+1}/{burst_size} | tokens: {tok_count}")
        cycle += 1
        if not _running:
            break
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
    max_cycles = read_cycles(profile)
    cycle = 0

    while _running:
        if max_cycles and cycle >= max_cycles:
            log(f"Completed {max_cycles} cycles — stopping")
            return
        burst_size = random.randint(burst_min, burst_max)
        log(f"Sending periodic burst of {burst_size} requests")
        token = keys.get_key()
        for i in range(burst_size):
            if not _running:
                return
            status, elapsed, tok_count = call_inference(token, prompt, model)
            log(f"💬 {status_str(status)} {elapsed:.2f}s | periodic {i+1}/{burst_size} | tokens: {tok_count}")
            if i < burst_size - 1:
                _interruptible_sleep(random.uniform(think_min, think_max))
        cycle += 1
        if not _running:
            break
        log(f"Periodic burst complete, long pause {pause}s")
        _interruptible_sleep(pause)


def _interruptible_sleep(seconds):
    end = time.time() + seconds
    while _running and time.time() < end:
        time.sleep(min(1, end - time.time()))


def _shutdown(signum, _frame):
    global _running
    _running = False


PATTERNS = {
    "conversational": run_conversational,
    "burst": run_burst,
    "periodic": run_periodic,
}


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


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--demo":
        demo_once()
        return

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    profile = load_profile(PROFILE_PATH)
    pattern = profile.get("pattern", "conversational")
    model = profile.get("model", MODEL_NAME)
    log(f"Starting agent (model={model}, pattern={pattern})")

    runner = PATTERNS.get(pattern)
    if not runner:
        log(f"Unknown pattern: {pattern}")
        sys.exit(1)

    tm = TokenManager()
    keys = ApiKeyManager(tm)

    # Mint API key (retry until success or shutdown)
    while _running:
        try:
            keys.get_key()
            break
        except urllib.error.HTTPError as e:
            log(f"🎫 {status_str(e.code)} API key mint failed — retrying in 30s")
            _interruptible_sleep(30)
        except Exception as e:
            log(f"🎫 {status_str(0)} API key mint error ({e}) — retrying in 30s")
            _interruptible_sleep(30)

    if _running:
        log(f"Running pattern: {pattern}")
        runner(profile, keys, model)
        log("⏹ done — idling until pod is stopped")
        while _running:
            time.sleep(60)


if __name__ == "__main__":
    main()
