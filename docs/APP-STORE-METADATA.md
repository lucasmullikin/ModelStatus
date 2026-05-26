# App Store Connect Submission Metadata — ModelStatus v1.0

**Developer:** Lucas Mullikin  
**Team ID:** ZFXWBW78LZ  
**Bundle ID:** com.lucasmullikin.ModelStatus  
**Price:** $6.99 (one-time)  
**Platform:** macOS

---

## 1. App Name

```
ModelStatus
```

11 characters. No change needed. Fits the 30-character limit with room for the subtitle to carry the description.

---

## 2. Subtitle

```
Local AI Server Monitor
```

23 characters. Pairs cleanly with the name: "ModelStatus — Local AI Server Monitor." Descriptive, searchable, no buzzwords.

---

## 3. Promotional Text

```
Monitor every local LLM server from one menu bar icon — Ollama, LM Studio, MLX, vLLM. No telemetry. Free updates forever.
```

122 characters. Can be updated without re-review; update this when a notable feature ships.

---

## 4. Description

```
See every local AI model server at a glance — without switching windows, without cloud dependencies, without a subscription.

WHAT IT DOES
• Monitors Ollama, LM Studio, vLLM, MLX, and any OpenAI-compatible server in parallel from a single menu bar icon.
• Shows which models are loaded, live VRAM usage, and whether inference is in flight right now.
• Eject or load models directly from the menu — no terminal required.
• Discovers servers automatically: Settings → Discover scans your local network and Tailscale peers for running model servers.
• Stores authorization headers (for tunneled or remote servers) securely in the macOS Keychain — never in any config file.
• Sends an opt-in notification when a server goes down or comes back up.
• Compact mode collapses the menu to one line per server when you have many instances running.

WHY IT EXISTS
Two devs in the local-LLM weeds built this for themselves. Running Ollama on a laptop, MLX on a Mac mini, and vLLM behind Tailscale means context-switching constantly just to see if a model is loaded. ModelStatus puts all of that on one status dot. We use it every day.

PRICING
$6.99, one-time. Free updates forever — no v2.0 upgrade fee, no subscription, no in-app purchases. Ever. The source code is also available for free on GitHub under the MIT license if you prefer to build it yourself.

PRIVACY
ModelStatus collects nothing. No telemetry, no analytics, no crash reports, no usage metrics. The only outbound network traffic is to the model servers you configure yourself. The LAN discovery scan is on-demand only — you tap Discover; it never runs in the background.

REQUIREMENTS
• macOS 13 Ventura or later
• At least one supported model server running locally or reachable on your network (Ollama, LM Studio, vLLM, MLX, or any OpenAI-compatible endpoint)

SANDBOX NOTE
The App Store build runs in the macOS sandbox. HTTP polling, model lists, eject/load via API, and LAN port-scan discovery all work normally. Features that require shell process inspection (client-process display, CPU/RSS readout, Start/Stop local Ollama, Tailscale peer discovery) are unavailable in the sandboxed build and are hidden gracefully — they are not shown as broken.

SUPPORT
GitHub Issues: https://github.com/lucasmullikin/ModelStatus/issues
Security disclosures: lucas@lucrativepictures.com
```

Character count: approximately 2,050. Well within the 4,000-character limit.

---

## 5. Keywords

```
ollama,llm,ai,locallm,menubar,mlx,vllm,lmstudio,modelmonitor,llama,inference,developer
```

89 characters (including commas). Within the 100-character limit.

Notes on choices:
- `ollama` — highest-volume search term for the audience; must be first.
- `llm`,`ai`,`locallm` — category terms.
- `menubar` — product-type search; many users search "menu bar app."
- `mlx`,`vllm`,`lmstudio` — provider names; users searching these are exactly the target.
- `modelmonitor`,`inference` — feature-level terms.
- `llama`,`developer` — broad reach terms with relevance.
- Do not include "ModelStatus" or "Lucrative Pictures" — Apple excludes your own app name and developer name from keyword scoring.

---

## 6. Support URL

**Recommendation: GitHub Issues.**

```
https://github.com/lucasmullikin/ModelStatus/issues
```

This is the correct choice for a developer-tools app with a developer audience. Your users will already be on GitHub. A custom support page adds maintenance overhead for no benefit at v1.0. Apple requires the URL to be live before submission; verify the repo is public.

---

## 7. Marketing URL

**Recommendation: GitHub repository homepage (v1.0).**

```
https://github.com/lucasmullikin/ModelStatus
```

The README is already a complete product page — feature list, screenshots, install instructions, FAQ. A custom landing page is worth building before a public marketing push (HN, r/LocalLLaMA) but is not required for App Store submission. Leave this field populated with the GitHub URL now; update it later if a landing page is built.

---

## 8. Category

**Primary:** Developer Tools  
**Secondary:** Utilities

Rationale: The primary audience is developers running local inference servers. "Developer Tools" surfaces the app to that audience explicitly. "Utilities" is the correct secondary — it is a menu bar utility. Do not use "Productivity"; that category is saturated and the audience mismatch hurts conversion.

---

## 9. Age Rating

**4+**

Justification: ModelStatus contains no user-generated content, no social features, no mature themes, no advertising, no in-app purchases beyond the initial price, and no web browsing. It makes HTTP requests only to servers the user configures. There is no content of any kind that would trigger a higher rating. Select 4+ in App Store Connect's questionnaire by answering "None" or "No" to every content question.

---

## 10. App Privacy Nutrition Labels

ModelStatus collects **no data of any kind**. Every category below should be declared **"Data Not Collected"** in App Store Connect.

| Data Type | Declaration |
|---|---|
| Contact Info (name, email, phone, address) | Data Not Collected |
| Health & Fitness | Data Not Collected |
| Financial Info | Data Not Collected |
| Location (precise or coarse) | Data Not Collected |
| Sensitive Info | Data Not Collected |
| Contacts | Data Not Collected |
| User Content (emails, messages, photos, audio, gameplay) | Data Not Collected |
| Browsing History | Data Not Collected |
| Search History | Data Not Collected |
| Identifiers (user ID, device ID, advertising ID) | Data Not Collected |
| Usage Data (product interaction, advertising data, crash data) | Data Not Collected |
| Diagnostics (crash logs, performance data) | Data Not Collected |
| Other Data | Data Not Collected |
| Purchases | Data Not Collected |

In App Store Connect, navigate to App Privacy → Data Types and select "No" for every category. The resulting nutrition label will display "No Data Collected."

---

## 11. Pricing Tier

**Tier 7 — $6.99 USD** (2026 Mac App Store pricing matrix).

Confirm before submission: log into App Store Connect → Pricing and Availability → set price to $6.99. Apple's pricing tiers auto-convert to local currencies. Tier 7 maps to approximately €6.99, £5.99, A$11.99, ¥1100 — verify these are acceptable before setting the price live.

Set availability to all territories unless there is a specific reason to restrict. No introductory pricing; no in-app purchases; no subscription.

---

## 12. Localization Scope

**v1.0 ships English (en-US) only.**

This is the correct decision. The target audience (local LLM developers) skews heavily English-first. Shipping a single well-polished English metadata set is better than shipping mediocre machine-translated metadata in ten languages.

Future localization is additive: each locale is an independent metadata record in App Store Connect and can be added after launch without a binary update or re-review. Priority locales if conversion data justifies it: Japanese (ja), German (de), Simplified Chinese (zh-Hans) — these are the top non-English locales for developer tools on the Mac App Store.

---

## 13. Version Notes ("What's New in This Version")

```
ModelStatus v1.0 — first Mac App Store release.

DEDICATED MLX SUPPORT
MLX is now a first-class provider: automatic port detection (HTTP 8080 / HTTPS 443), HuggingFace cache enumeration so the menu shows what could be loaded without a server restart, and local-process argv verification so the app never exposes your cache to a non-MLX endpoint.

PRIVACY-SCRUBBED DIAGNOSTICS
Export a diagnostic bundle from the menu. Before the zip is written, every hostname and URL in the logs is replaced with a salted SHA-256 token — the salt lives in your Keychain and never leaves your machine. Auth headers and credentials are fully redacted. You can attach the bundle to a GitHub issue without exposing any server details.

LAN + TAILSCALE DISCOVERY
Settings → Discover scans your local /24 subnet and known Tailscale peers simultaneously. Servers found are added with one click. The scan is always on-demand — it never runs in the background without your action.

SECURITY HARDENING
URL validation now blocks octal, hex, decimal, and shortened IPv4 forms; compressed IPv6; link-local addresses; Tailscale CGNAT range; and all RFC 1918 / cloud-metadata literals. DNS-rebinding is mitigated by a pre-resolution check. HTTP responses are capped at 4 MB with no redirects permitted.

FREE UPDATES FOREVER
This is a one-time purchase. Every future update — new providers, new features, bug fixes — is included at no additional cost. No subscription. No upgrade fee.

Source code: https://github.com/lucasmullikin/ModelStatus (MIT)
Issues: https://github.com/lucasmullikin/ModelStatus/issues
```

Character count: approximately 1,380. Within the 4,000-character limit.

---

## 14. App Review Notes (private — Apple reviewers only)

```
Thank you for reviewing ModelStatus.

IMPORTANT: This app requires a running local AI model server (Ollama, LM Studio, MLX, etc.) to show live data. Reviewers will not have one installed, and that is expected. The app handles this gracefully — here is what to verify:

1. DEFAULT STATE (NO SERVER INSTALLED)
Launch the app. The 🧠 brain icon appears in the menu bar. Click it. The default entry "Local" (http://127.0.0.1:11434) will show a red dot and the label "Unreachable." This is correct behavior — it means the app successfully attempted to reach Ollama's default port and got no response. No crash, no error dialog. The menu is fully functional.

2. SETTINGS WINDOW
Click the menu bar icon → Settings. The Settings window opens. You will see:
- A list with one row: "Local — http://127.0.0.1:11434"
- An "Add" button (adds a server manually)
- A "Discover…" button (scans the local network)
Both buttons should be present and tappable.

3. DISCOVER BUTTON
Click Discover…. The app scans the local /24 subnet and any Tailscale peers for known model-server ports. In the reviewer environment there will be no servers running, so the scan will complete and return zero results. This is correct. The scan takes up to ~10 seconds; a progress indicator is shown during the scan. No crash, no hang.

4. MENU BAR ICON
The menu bar icon is the 🧠 brain symbol (Unicode U+1F9E0 rendered as an NSImage template). It does not animate when idle. It updates its color dot (green/blue/yellow/red) based on the worst-status server in the list.

5. SANDBOX + LocalSystemAccess DEGRADATION
The App Store build is compiled with the MODELSTATUS_APP_STORE flag, which substitutes SandboxedLocalSystemAccess for the direct lsof/ps/pgrep implementation. As a result:
- The "Client Process" field (shows which app is currently prompting a model) will not appear.
- The CPU % and RAM (RSS) readout will not appear.
- The "Start Ollama" / "Stop Ollama" menu items will not appear.
- Tailscale peer discovery will not appear in the Discover results.
These are not bugs. They are intentional graceful degradations required by the macOS sandbox. The app hides these controls entirely rather than showing them as disabled or erroring. HTTP polling, model lists, eject/load via API, and LAN port-scan discovery all function normally.

6. NETWORK ACCESS
The app makes outbound HTTP/HTTPS requests only to the URLs the user configures (default: http://127.0.0.1:11434). NSAllowsLocalNetworking is set to YES in the app's ATS configuration to permit plain HTTP to loopback addresses, which is required for Ollama's default setup. This is standard practice for local-server tools.

7. KEYCHAIN USAGE
If you click Settings → select a row → Edit Auth…, the app will prompt for Keychain access to store the authorization header. This is expected behavior. The header is stored with kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly and is never written to disk in plaintext.

Contact for review questions: lucas@lucrativepictures.com
```

Character count: approximately 2,350. Within the 4,000-character limit.

---

## Checklist Before Submitting

- [ ] App Store Connect account active under Team ID ZFXWBW78LZ
- [ ] Binary built with `MODELSTATUS_APP_STORE=1` compile flag
- [ ] Binary signed with Distribution certificate and App Store provisioning profile
- [ ] Bundle version (`CFBundleVersion`) incremented to at least 5 for v1.0 (current is 4 in Info.plist)
- [ ] `CFBundleShortVersionString` set to `1.0`
- [ ] Screenshots prepared: at minimum one 1280×800 or 1440×900 macOS screenshot (menu open, showing status dots and a model list)
- [ ] App icon provided at 1024×1024 PNG (no alpha channel)
- [ ] Support URL live and returning HTTP 200
- [ ] Privacy nutrition labels all set to "Data Not Collected"
- [ ] Price set to Tier 7 ($6.99)
- [ ] Age rating questionnaire completed (all None/No → 4+)
