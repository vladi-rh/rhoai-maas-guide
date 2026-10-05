# Agent Behavior Profiles

Each YAML file defines the traffic pattern for one agent category. Profiles are mounted into agent pods as a ConfigMap and read by `agent/agent.py` at startup via the `PROFILE_PATH` env var.

| Profile | Pattern | Description |
|---------|---------|-------------|
| `chatbot-profile.yaml` | `conversational` | One request at a time, human-paced pauses (3–8 s) between. Simulates interactive chat. |
| `reviewer-profile.yaml` | `burst` | Batch of 3–5 requests in quick succession, then a long pause (10–30 s). Simulates batch code review. |
| `analyst-profile.yaml` | `periodic` | Rapid burst of 5–10 metric queries, then a 30 s idle. Simulates scheduled reporting jobs. |

## Keys

| Key | Used by | Meaning |
|-----|---------|---------|
| `pattern` | all | Traffic pattern: `conversational`, `burst`, or `periodic` |
| `promptTemplate` | all | Prompt sent to the model (placeholder substitution is illustrative — agent sends it as-is) |
| `thinkTimeMinSec` / `thinkTimeMaxSec` | all | Random pause range between requests or bursts |
| `burstSize` | `conversational` | Fixed requests per iteration (always 1) |
| `burstSizeMin` / `burstSizeMax` | `burst`, `periodic` | Random burst size range |
| `pauseAfterBurstSec` | `periodic` | Fixed idle after each burst |
