# ModelStatus Privacy Policy

**Last updated: 2026-05-26**
**Version: 1.0 (matches ModelStatus v1.0)**

## TL;DR

**ModelStatus collects nothing. No telemetry, no analytics, no cloud,
no account, no tracking, no ads, no profiling, no data sale, no data
sharing.** Network traffic only goes to the LLM servers you configure
and (direct-download builds only) to github.com once a day to check
for new versions.

Because ModelStatus collects no personal data of any kind, the rights
granted to you under California's CCPA/CPRA, the EU/UK GDPR, and the
Virginia VCDPA / Colorado CPA / Utah UCPA / Connecticut CTDPA / Texas
TDPSA / Oregon OCPA all reduce to one outcome: **there is nothing
to access, correct, delete, port, restrict, or opt out of, because
there is no data.**

That said, the full rights and procedures applicable in each
jurisdiction are spelled out below for transparency and so you have
named contacts if you wish to exercise them.

---

## 1. What ModelStatus is

ModelStatus is a macOS menu bar application that monitors local
HTTP-accessible AI model servers (Ollama, LM Studio, vLLM, MLX,
llama.cpp, and any OpenAI-compatible API).

**Data Controller (for GDPR / UK GDPR purposes):**

- **Name:** Lucas Mullikin (sole individual developer)
- **Jurisdiction of establishment:** United States (Boise, Idaho)
- **Email:** lucas@lucasmullikin.com
- **Apple Developer Team ID:** ZFXWBW78LZ
- **EU/UK Representative:** Not appointed. Under Article 27(2)(a) GDPR,
  a non-EU controller is exempt from appointing an EU representative
  when its processing is *occasional, does not involve large-scale
  processing of special-category or criminal data, and is unlikely to
  result in a risk to the rights and freedoms of natural persons.*
  ModelStatus processes **no personal data at all** — the Article
  27(2)(a) exemption applies. If processing scope ever changes, an
  EU representative will be appointed before the change takes effect.

Source code is available at <https://github.com/lucasmullikin/ModelStatus>
under the MIT License.

## 2. What data ModelStatus collects

**None.** ModelStatus does not collect, store, transmit, sell, share,
disclose, profile, or otherwise process any personal data or telemetry
from users.

The 14 Apple App Privacy data categories — all answered "Data Not
Collected":

- Contact Info, Health & Fitness, Financial Info, Location,
  Sensitive Info, Contacts, User Content, Browsing History,
  Search History, Identifiers, Purchases, Usage Data, Diagnostics,
  Other Data.

**Lawful basis (Article 6 GDPR):** Not applicable. No processing of
personal data occurs, so no lawful basis is required.

**Categories of recipients:** None. No personal data is disclosed to
any recipient under any circumstance.

**International data transfers:** None. Because no personal data is
collected, no data is transferred to any third country or
international organization.

**Retention period:** Not applicable. The only data that exists is
the local configuration on your own Mac, which persists until you
delete the application or remove the relevant files (see Section 5).

## 3. What network connections ModelStatus makes

ModelStatus connects only to:

1. **The LLM server URLs you explicitly configure** in the Settings
   window or via the Discovery scan. Connections poll `/api/tags`,
   `/api/ps`, `/v1/models`, `/metrics`, etc. at the interval you
   choose (default 5 seconds). Polling stops when ModelStatus quits.
2. **Your local network (`/24` subnet)** — only when you press the
   "Discover" button. ModelStatus scans the common model-server
   ports (11434, 1234, 8080, 8000, 10240, 5001) and reports
   responding hosts. The scan does not run automatically.
3. **Tailscale peers** — only when you press the "Discover" button
   AND Tailscale.app is installed on your Mac. ModelStatus calls
   the local `tailscale status --json` command and probes the
   reported peers.
4. **github.com** (direct-download builds only) — once every 24
   hours, ModelStatus fetches
   `https://api.github.com/repos/lucasmullikin/ModelStatus/releases/latest`
   to check for new versions. **No user identifier, telemetry,
   cookie, query string, custom header, IP-revealing token, or
   analytics payload is sent — only the standard `User-Agent` and
   `Accept` headers and the host's source IP that GitHub's servers
   inherently observe.** GitHub's own logging of that request is
   subject to GitHub's privacy policy, not this one. Apple App Store
   builds skip this check entirely (Apple's auto-update mechanism
   handles updates).

ModelStatus never makes any other outbound connection. There is no
backend service, no usage tracking, no error reporting service,
no SDK that could phone home.

## 4. Tracking & Profiling

**ModelStatus does not engage in any form of tracking, cross-site
tracking, cross-app tracking, profiling, or behavioral advertising.**

Specifically:

- **No `IDFA` / advertising identifier access.** ModelStatus does
  not request, read, or transmit any device identifier.
- **No App Tracking Transparency (ATT) prompt** is shown because
  there is nothing to track.
- **No third-party advertising SDKs, analytics SDKs, attribution
  SDKs, fingerprinting libraries, or session-replay tools** are
  linked into the binary.
- **No CCPA/CPRA "sale" or "share" of personal information** occurs
  or could occur — there is no personal information to sell or share.
- **No automated decision-making or profiling under GDPR Article 22**
  takes place.

## 5. What data ModelStatus stores locally

All data stays on your Mac. None of it is transmitted off-device.
Specifically:

1. **`~/Library/Preferences/com.lucasmullikin.ModelStatus.json`**
   (file mode `0600` — owner-readable only) — your server list, poll
   interval, notification preference, compact-menu preference.
2. **macOS Keychain** items with service identifier
   `com.lucasmullikin.ModelStatus.auth` — Authorization headers
   you've optionally set for individual servers.
   Accessibility: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
   (no iCloud Keychain sync; this device only).
3. **macOS Keychain** items with service identifier
   `com.lucasmullikin.ModelStatus.anon` — a random salt used to
   anonymize hostnames in exported diagnostic bundles (see Section 6).
   Generated once on first diagnostic-bundle export.
4. **`UserDefaults` (`NSUserDefaults`)** under the app's bundle ID —
   small bookkeeping values used to suppress duplicate update
   notifications: the most-recently-seen GitHub release tag, last
   check timestamp, dismissed/snoozed version list. These never leave
   your device. (Declared in the app's Privacy Manifest with reason
   code `CA92.1` — "access info from same app".)
5. **macOS unified log (OSLog)** — runtime log entries under
   subsystem `com.lucasmullikin.ModelStatus`. Standard macOS log
   storage; visible in Console.app. ModelStatus's in-app Log
   Viewer reads from this same store via `OSLogStore.local()`.

**To delete all locally stored data,** quit ModelStatus, then:

- Drag ModelStatus.app to the Trash
- Run in Terminal:
  ```
  rm -f ~/Library/Preferences/com.lucasmullikin.ModelStatus.json
  defaults delete com.lucasmullikin.ModelStatus 2>/dev/null
  security delete-generic-password -s com.lucasmullikin.ModelStatus.auth 2>/dev/null
  security delete-generic-password -s com.lucasmullikin.ModelStatus.anon 2>/dev/null
  log erase --process com.lucasmullikin.ModelStatus 2>/dev/null
  ```

This is a complete erasure. No remote copies exist (because none were
ever made).

## 6. Diagnostic Bundle Export

If you trigger **Settings → Diagnostics → Export Diagnostic Bundle…**,
ModelStatus creates a `.zip` file with:

- Recent log entries (last 1 hour, capped at 1000 lines)
- A snapshot of your server config (hostnames are anonymized via
  salted SHA-256 — the salt lives in your Keychain and never leaves
  your device)
- macOS version, hardware model, available memory
- A list of running processes **by name only** (no full command lines)

All output is privacy-scrubbed. Hostnames are replaced with
`host-<64hex>` tokens that are stable across the bundle but cannot
be reversed back to the original hostname (the salt is required
and never leaves your device). Auth headers, API keys, query
strings, and URL credentials are explicitly redacted.

The bundle is written to a location **you select** via the standard
macOS Save Panel. ModelStatus does not upload the bundle anywhere —
it's yours to do with as you wish (e.g., attach to a GitHub issue
when reporting a bug). **You are solely in control of the bundle
after export.**

This feature is **disabled in the App Store sandboxed build** (the
underlying `sw_vers` / `sysctl` / `ps` shell calls aren't permitted
under sandbox). It remains available in the direct-download build.

## 7. Notifications

If you enable "Notify on reachability change" in Settings, ModelStatus
will request macOS notification permission and post **local**
notifications when one of your configured servers becomes unreachable
or comes back. These are standard macOS notifications generated
on-device. No notification content is transmitted anywhere.

You can revoke notification permission at any time in
**System Settings → Notifications → ModelStatus**.

## 8. Third-Party Services

None. ModelStatus has no third-party SDKs, no analytics frameworks,
no ad networks, no crash reporters, no attribution providers, no
A/B-testing services, no remote config services. The binary
statically links only Apple's standard frameworks (Foundation,
AppKit, CryptoKit, OSLog, Security, ServiceManagement,
UserNotifications, UniformTypeIdentifiers).

## 9. Children's Privacy

ModelStatus is **not directed to children under 13** and does not
knowingly collect, store, use, or disclose any data from anyone of
any age (including, by definition, children). Age rating: **4+**
(no restricted content; the app exists solely to display the status
of LLM servers the user has configured themselves).

This satisfies the Children's Online Privacy Protection Act (COPPA,
15 U.S.C. §§ 6501–6506) by collecting no data from any user, which
necessarily includes no data from children under 13.

## 10. California Residents — CCPA / CPRA Rights

The California Consumer Privacy Act of 2018 ("CCPA"), as amended by
the California Privacy Rights Act of 2020 ("CPRA"), grants California
residents certain rights regarding their personal information.

**Our applicability:** ModelStatus is published by an individual
developer who does not meet the CCPA's business thresholds
(Cal. Civ. Code § 1798.140(d)(1)). The disclosures below are
nevertheless provided voluntarily for transparency.

**Categories of personal information collected in the preceding 12
months:** None.

**Categories of sources of personal information:** None.

**Business or commercial purposes for collecting:** None.

**Categories of third parties with whom personal information is
shared:** None.

**Sale or sharing of personal information:** ModelStatus does **NOT
sell or share** any personal information, as those terms are defined
in Cal. Civ. Code § 1798.140(ad)–(ah). We have not sold or shared
personal information in the preceding 12 months.

**Use of sensitive personal information:** None collected, none used.

### Your California rights:

- **Right to Know** (§ 1798.100, .110, .115) — the categories and
  specific pieces of personal information collected about you,
  sources, purposes, and recipients. *Answer for ModelStatus: none,
  none, none, none.*
- **Right to Delete** (§ 1798.105) — request deletion of personal
  information. *Answer: nothing to delete.*
- **Right to Correct** (§ 1798.106) — request correction of
  inaccurate personal information. *Answer: nothing to correct.*
- **Right to Opt Out of Sale/Sharing** (§ 1798.120, .135) — opt out
  of the sale or sharing of personal information. *Answer: no
  sale/sharing occurs; nothing to opt out of.*
- **Right to Limit Use of Sensitive Personal Information**
  (§ 1798.121) — *Answer: no sensitive PI is collected.*
- **Right to Non-Discrimination** (§ 1798.125) — ModelStatus will
  not deny service, charge different prices, or provide a different
  level of quality because you exercise any CCPA right.
- **Right to Portability** (§ 1798.130) — receive a copy of personal
  information in a portable, machine-readable format. *Answer:
  nothing to port.*

### How to exercise:

Email **lucas@lucasmullikin.com** with the subject line
**"CCPA Request — \[Right You Wish to Exercise\]"**. We will respond
within 45 days as required by § 1798.130(a)(2). Identity will be
verified by confirming control of the email account used to make
the request (no additional identifiers are collected or held).

You may also designate an authorized agent to make a request on
your behalf under § 1798.135(b)(1).

## 11. EU / EEA / UK Residents — GDPR & UK GDPR Rights

The General Data Protection Regulation (Regulation (EU) 2016/679,
"GDPR") and the United Kingdom GDPR (Data Protection Act 2018)
grant individuals in the EU, EEA, and UK ("data subjects") certain
rights regarding processing of their personal data.

**Our processing scope:** None. ModelStatus does not collect,
record, organize, structure, store, adapt, retrieve, consult, use,
disclose, transmit, disseminate, align, combine, restrict, erase,
or destroy any personal data of any data subject (Article 4(2) GDPR
"processing" definition). The Article 27(2)(a) representative
exemption applies (see Section 1).

### Your rights nevertheless (Articles 12–22 GDPR):

- **Article 13/14 — Right to Information** about processing
  performed. *Answer: this policy is the information; processing
  is none.*
- **Article 15 — Right of Access** to your personal data. *Answer:
  nothing held, nothing to provide.*
- **Article 16 — Right to Rectification** of inaccurate personal
  data. *Answer: nothing held, nothing to rectify.*
- **Article 17 — Right to Erasure** ("right to be forgotten").
  *Answer: nothing held, nothing to erase. To delete the local
  config on your own Mac, see Section 5.*
- **Article 18 — Right to Restriction** of processing. *Answer: no
  processing to restrict.*
- **Article 20 — Right to Data Portability**. *Answer: nothing held
  to port.*
- **Article 21 — Right to Object** to processing. *Answer: no
  processing to object to.*
- **Article 22 — Rights related to automated decision-making**,
  including profiling. *Answer: no automated decisions and no
  profiling occur.*

### How to exercise:

Email **lucas@lucasmullikin.com** with the subject line
**"GDPR Request — \[Right You Wish to Exercise\]"**. A response
will be provided within one month, as required by Article 12(3).

### Right to Lodge a Complaint (Article 77 GDPR):

You have the right to lodge a complaint with a supervisory authority
in your EU/EEA member state or, for UK residents, with the
Information Commissioner's Office (ICO, <https://ico.org.uk>).

A directory of EU/EEA Data Protection Authorities is maintained
by the European Data Protection Board at
<https://edpb.europa.eu/about-edpb/about-edpb/members_en>.

## 12. Other US State Privacy Laws

The following state privacy laws contain rights and disclosures
similar to the CCPA. None of these is triggered by ModelStatus
because no personal data is collected; the disclosures below are
provided for completeness:

- **Virginia Consumer Data Protection Act (VCDPA),** Va. Code
  § 59.1-575 et seq. (effective 2023-01-01).
- **Colorado Privacy Act (CPA),** Colo. Rev. Stat. § 6-1-1301 et
  seq. (effective 2023-07-01).
- **Connecticut Data Privacy Act (CTDPA),** Conn. Gen. Stat.
  § 42-515 et seq. (effective 2023-07-01).
- **Utah Consumer Privacy Act (UCPA),** Utah Code § 13-61-101 et
  seq. (effective 2023-12-31).
- **Texas Data Privacy and Security Act (TDPSA),** Tex. Bus. & Com.
  Code § 541.001 et seq. (effective 2024-07-01).
- **Oregon Consumer Privacy Act (OCPA),** Or. Rev. Stat. § 646A.570
  et seq. (effective 2024-07-01).
- **Montana Consumer Data Privacy Act,** Mont. Code Ann. § 30-14-2801
  et seq. (effective 2024-10-01).
- **Tennessee Information Protection Act,** Tenn. Code Ann.
  § 47-18-3201 et seq. (effective 2025-07-01).

Under each of these laws you have, in summary, rights of access,
correction, deletion, portability, and opt-out of targeted
advertising/sale/profiling. **For all of them, the answer is the
same: ModelStatus collects, processes, sells, shares, profiles, and
targets nothing — so each right reduces to a trivially satisfied
no-op.** Email **lucas@lucasmullikin.com** with the subject line
**"\[State\] Privacy Request — \[Right\]"** to exercise any of these.

## 13. Data Security

While no personal data is collected, the local data described in
Section 5 is protected with standard macOS mechanisms:

- Configuration file at file mode `0600` (owner-only readable).
- Credential storage in the macOS Keychain with
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
- The application binary is signed with a Developer ID Application
  certificate (direct-download builds) or an Apple Distribution
  certificate (App Store builds) and runs with the macOS hardened
  runtime enabled.
- The App Store build runs inside the macOS App Sandbox with a
  minimal entitlement set.

Because no data is transmitted off-device, the risks normally
addressed by transit-layer security, breach notification, and
breach-response procedures **do not arise**. There is no server-side
data store that could be breached and no transmission channel
through which user data could be intercepted.

## 14. Children & COPPA

Repeated for emphasis: ModelStatus does not knowingly collect
personal information from anyone, of any age. Specifically,
ModelStatus does not collect personal information from children
under 13 within the meaning of the Children's Online Privacy
Protection Act (COPPA, 15 U.S.C. §§ 6501–6506). The product is
not directed to children. The App Store age rating is **4+**.

## 15. Changes to this Policy

If this policy materially changes, the new version will be posted
at the same URL with an updated "Last updated" date and (where the
change is material to user rights) noted in the app's release notes.
Past versions remain available in the project's `git` history at
<https://github.com/lucasmullikin/ModelStatus/commits/main/docs/PRIVACY.md>.

## 16. Contact

- **General privacy questions / data-rights requests:**
  lucas@lucasmullikin.com
- **GitHub Issues:** <https://github.com/lucasmullikin/ModelStatus/issues>
- **Security disclosures (preferred channel for vulnerabilities):**
  see `SECURITY.md` in the repository for the disclosure procedure.

## 17. Jurisdiction & Governing Law

ModelStatus is developed in the United States (Boise, Idaho). Your
use of the software is subject to the MIT License terms in `LICENSE`
and, for App Store distribution, Apple's standard EULA. Disputes
arising under this Privacy Policy are governed by the laws of the
State of Idaho, USA, without prejudice to any non-waivable consumer
protections available to you under the laws of your jurisdiction of
residence (including, without limitation, CCPA/CPRA for California
residents and GDPR/UK GDPR for EU/EEA/UK residents).
