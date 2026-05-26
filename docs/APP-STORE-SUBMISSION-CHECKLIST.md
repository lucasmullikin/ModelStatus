# App Store Submission Checklist — ModelStatus v1.0

Pre-filled answers for every App Store Connect form. Paste from
here when you click through the submission wizard.

## Export Compliance (Encryption questionnaire)

**Q1: "Is your app designed to use cryptography or does it contain
or incorporate cryptography?"**

→ **Yes**

**Q2: "Does your app meet any of the following: (a) Qualifies for
one or more exemptions provided under category 5 part 2 of the U.S.
Export Administration Regulations?"**

→ **Yes — exempt under Note 4 of Category 5 Part 2.**

Rationale (in case Apple asks): ModelStatus uses cryptography only as:
1. CryptoKit SHA-256 for log/URL anonymization (standard hash, not
   encryption — `Anonymizer.hashHost()`)
2. macOS Keychain API for storing auth headers + anonymizer salt
   (standard OS-provided storage, not custom crypto)
3. URLSession HTTPS connections (standard TLS via OS, not custom
   encryption)

All three fall under the "uses standard cryptography in the OS or
a standard cryptographic library" exemption. No CCATS / ECCN
classification required.

**Q3: "Does your app implement any proprietary encryption algorithms?"**

→ **No**

**Q4: "Is your app available on the French App Store?"**

→ **Yes** (no restrictions for our usage)

## App Privacy Nutrition Labels

**Every category: Data Not Collected.**

| Data type | Answer |
|---|---|
| Contact Info | Data Not Collected |
| Health & Fitness | Data Not Collected |
| Financial Info | Data Not Collected |
| Location | Data Not Collected |
| Sensitive Info | Data Not Collected |
| Contacts | Data Not Collected |
| User Content | Data Not Collected |
| Browsing History | Data Not Collected |
| Search History | Data Not Collected |
| Identifiers | Data Not Collected |
| Purchases | Data Not Collected |
| Usage Data | Data Not Collected |
| Diagnostics | Data Not Collected |
| Other Data | Data Not Collected |

**Privacy Policy URL (required field):**

`https://github.com/lucasmullikin/ModelStatus/blob/main/docs/PRIVACY.md`

(Or host on a custom domain later, e.g.
`https://modelstatus.app/privacy` — the GitHub URL is sufficient
for initial submission.)

## Pricing & Availability

| Field | Value |
|---|---|
| Price | $6.99 USD (Tier 7) |
| Available territories | All available territories |
| Pre-order | No |
| Family Sharing | Yes |
| Educational Discount | No |
| Volume Purchase | Yes (Apple Business Manager) |

## Age Rating Questionnaire

| Question | Answer |
|---|---|
| Unrestricted Web Access | No |
| Gambling | No |
| Mature/Suggestive Themes | None |
| Profanity / Crude Humor | None |
| Violence — Cartoon or Fantasy | None |
| Violence — Realistic | None |
| Horror / Fear Themes | None |
| Sexual Content / Nudity | None |
| Alcohol, Tobacco, or Drug Use | None |
| Medical / Treatment Info | None |
| Contests | None |

→ **Resulting rating: 4+**

## App Review Information

| Field | Value |
|---|---|
| Sign-In Required | No |
| Demo Account | Not applicable |
| Contact First Name | Lucas |
| Contact Last Name | Mullikin |
| Contact Email | lucas@lucasmullikin.com |
| Contact Phone | (your phone, required) |
| Review Notes | See `docs/APP-STORE-METADATA.md` Section 14 |

## Build Configuration (Xcode → Archive workflow)

| Field | Value |
|---|---|
| Build platform | macOS |
| Minimum macOS deployment | 13.0 (Ventura) |
| Architecture | arm64 (Apple Silicon) |
| Code signing identity | Apple Distribution: Lucas Mullikin (ZFXWBW78LZ) |
| Provisioning profile | Auto (managed by Xcode) |
| Entitlements file | `ModelStatus/ModelStatus-AppStore.entitlements` |
| Compile flag | `-DMODELSTATUS_APP_STORE` |

## Bundle Metadata

| Field | Value |
|---|---|
| Bundle Display Name | `ModelStatus` |
| Bundle Identifier | `com.lucasmullikin.ModelStatus` |
| CFBundleShortVersionString | `1.0` |
| CFBundleVersion | `100` |
| Copyright | `Copyright © 2026 Lucas Mullikin. MIT License.` |

## Order of Operations

1. ✅ Apple Developer enrollment active (ZFXWBW78LZ)
2. ✅ Code signing certs generated (Apple Development, Apple
   Distribution, Developer ID Application)
3. ⏳ App icon: 1024×1024 source + AppIcon.co for the full
   .icns set
4. ⏳ Privacy Policy hosted (GitHub URL works for v1.0)
5. ⏳ Info.plist version bump: 0.2.1 → 1.0, build 5 → 100
6. ⏳ Build sandboxed: `./scripts/build-app.sh --app-store`
7. ⏳ Sign with Apple Distribution:
   `codesign --force --options runtime --timestamp \
   --entitlements ModelStatus/ModelStatus-AppStore.entitlements \
   --sign "Apple Distribution: Lucas Mullikin (ZFXWBW78LZ)" \
   build/ModelStatus.app`
8. ⏳ Screenshots captured (5 at 2560×1600)
9. ⏳ Archive in Xcode (or via xcodebuild) + Upload to App Store
   Connect via Xcode → Window → Organizer → Distribute App
10. ⏳ In App Store Connect: fill metadata from
    `docs/APP-STORE-METADATA.md`, privacy answers from this file
11. ⏳ Click "Submit for Review"
12. ⏳ Wait 24-72 hours
13. ⏳ Approve "Released for sale" once Apple approves

## Common rejection causes to pre-empt (from prior indie launches)

- **"App appears to be a duplicate of another app"** — flag in your
  review notes that you're the developer of the open-source project
  on GitHub (link to the repo's package.json equivalent — your
  Info.plist + LICENSE)
- **"App does not run in sandbox"** — pre-verified via the
  architect-D54 gate; entitlements file declares `app-sandbox=true`
- **"App scans network"** — review notes explicitly explain LAN
  scan is user-initiated only, never automatic
- **"Missing privacy policy"** — URL provided per above
- **"Crashes during review"** — run the sandboxed build locally
  before upload; exercise every menu item

## Post-approval

- Tag `v1.0.0` in git (creates GitHub release)
- Update Homebrew tap to v1.0.0 (or sunset the tap in favor of
  App Store, per your strategy choice)
- Update README with App Store badge
- Post launch announcement to the channels in `docs/launch-posts.md`
- File post-launch v1.1 ticket for: localization, app preview video,
  AppleArchive migration in DiagnosticBundle (re-enables it for App
  Store)
