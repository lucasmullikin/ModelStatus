# Launch posts — ready-to-paste drafts

Pick a venue, copy the block, post when ready. **Don't post the same thing simultaneously to multiple Reddit subs** — looks spammy.

---

## Show HN

**Title** (max ~80 chars):

> Show HN: ModelStatus – Menu bar app for monitoring local LLM servers on macOS

**Body**:

```
Built this because I have Ollama on my laptop, MLX on a Mac mini, and a remote vLLM box behind Tailscale — and there's no single tool that shows me what's loaded on each, how much VRAM is in use, and who's actually hitting them right now.

ModelStatus puts a 🧠 in your menu bar with one colored dot per server (active / generating / idle / unreachable). Click for details: loaded models, VRAM, CPU, who's connected (via lsof for local instances), last-active time, response latency.

Auto-detects which kind of backend each URL is (Ollama → /api/ps, LM Studio → /api/v0/models, vLLM → /metrics, anything else → /v1/models). Eject + load models from the menu where the backend supports it. Network discovery scans your /24 and Tailscale peers for known model-server ports.

Swift, AppKit, no dependencies. macOS 13+. MIT. No telemetry, no analytics, no account.

  brew tap lucasmullikin/tap
  brew install --cask modelstatus

Source: https://github.com/lucasmullikin/ModelStatus
```

---

## r/LocalLLaMA

**Title**:

> [Tool] ModelStatus — Free macOS menu bar app for monitoring multiple local LLM servers (Ollama / LM Studio / vLLM / MLX / llama.cpp)

**Body**:

```
I run Ollama on my Mac Studio, MLX on a Mac mini, and vLLM on a Linux box behind Tailscale. Wanted one place to see what's loaded where, how much VRAM is being used, who's hitting each server, and whether anything is generating right now. Nothing existed that did multi-instance + multi-backend, so I built it.

ModelStatus lives in your menu bar. One colored dot per server:
- 🟢 active (models loaded)
- 🔵 generating (only for Ollama — it actually exposes that)
- 🟡 idle (reachable, nothing loaded)
- 🔴 unreachable

Click for the full per-server view: model names, VRAM, eject/load from the menu (Ollama + LM Studio supported), CPU/memory of the local server process, which process is currently talking to it (Python? curl? Claude?), last-active time, request latency.

Network discovery: clicks a button, scans your LAN /24 and Tailscale peers for the common ports (11434, 1234, 8080, 8000), shows you a list with checkboxes.

Open source, MIT, written in Swift / AppKit. No dependencies. No telemetry, no analytics, no cloud, no account. macOS 13+ only for now — Linux/Windows on the roadmap.

  brew tap lucasmullikin/tap
  brew install --cask modelstatus

Source + Releases: https://github.com/lucasmullikin/ModelStatus

Built tonight, v0.1.0-beta. Bugs welcome.
```

---

## r/macapps

**Title**:

> ModelStatus — Free menu bar app for monitoring local AI model servers (Ollama, LM Studio, etc.)

**Body**: same as r/LocalLLaMA but tighter for non-AI-specialists. Drop the third paragraph about discovery details.

---

## Twitter / X thread

**Tweet 1** (hook):

> Just shipped ModelStatus 🧠
>
> macOS menu bar app for monitoring every local LLM server you're running at once — Ollama, LM Studio, vLLM, MLX, llama.cpp.
>
> Free, MIT, no telemetry.
>
> brew tap lucasmullikin/tap && brew install --cask modelstatus
>
> https://github.com/lucasmullikin/ModelStatus

**Tweet 2** (screenshot):

> One brain 🧠, one colored dot per server. Green = active, blue = generating, yellow = idle, red = down. Click to see what's loaded, how much VRAM, who's hitting it.
>
> [attach dropdown.png]

**Tweet 3** (network discovery):

> Built-in discovery scans your LAN + Tailscale peers for the common model-server ports. Click "Discover" in Settings, pick what to add.

**Tweet 4** (tagging):

> Works with @ollama, @LMStudioAI, @vllm_project, llama.cpp, MLX, and anything else that speaks /v1/models. Auto-detects the backend kind.
>
> v0.1.0-beta tonight. Bug reports welcome.

---

## Ollama community integrations PR

**Repo to PR**: https://github.com/ollama/ollama

**File**: README.md → "Community Integrations" section → "Apple Vision Pro" or "Desktop" subsection.

**Line to add** (one row alphabetically within the section):

```
- [ModelStatus](https://github.com/lucasmullikin/ModelStatus) (Menu bar app for monitoring Ollama and other local LLM servers on macOS)
```

**PR title**: `Add ModelStatus to Community Integrations`

**PR body**:

```
Adds ModelStatus to the macOS desktop integrations list.

ModelStatus is a free, open-source (MIT) macOS menu bar app for monitoring one or more local LLM servers — Ollama plus LM Studio, vLLM, llama.cpp, MLX, and any other OpenAI-compatible server. It auto-detects which backend each configured URL is, supports eject/load from the menu, and includes LAN + Tailscale-peer discovery.

- Source: https://github.com/lucasmullikin/ModelStatus
- Install: `brew tap lucasmullikin/tap && brew install --cask modelstatus`

No code change to Ollama itself.
```

---

## Awesome-list submissions

PR to each:
- https://github.com/jaywcjlove/awesome-mac → "AI" or "Menubar" section
- https://github.com/iCHAIT/awesome-macOS → similar
- https://github.com/Hannibal046/Awesome-LLM → "Tools" or "UI" section
- (if it exists) any awesome-ollama list

Same blurb in each:

```
- [ModelStatus](https://github.com/lucasmullikin/ModelStatus) — Free, open-source macOS menu bar app for monitoring multiple local LLM servers (Ollama, LM Studio, vLLM, MLX, llama.cpp). Multi-instance, auto-provider-detect, LAN + Tailscale discovery, no telemetry.
```
