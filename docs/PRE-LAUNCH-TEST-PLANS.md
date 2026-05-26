# ModelStatus — Pre-Launch Test Plans

Manual test plans to execute before every App Store submission.
Each plan is self-contained. Run them in order; allow 40–45 minutes total.

---

## Before You Begin — Common Setup

- Build the **release** variant (`Product → Archive` or `xcodebuild -configuration Release`).
- Install the resulting `ModelStatus.app` to `/Applications` before running any plan.
- Have Console.app open filtered on `com.lucasmullikin.ModelStatus` throughout.
- After each plan, quit ModelStatus fully via menu → "Quit ModelStatus" before starting the next plan.

---

## Test Plan 1 — First-Launch UX Walkthrough

**Estimated time:** ~5 minutes  
**Goal:** Verify first-run Welcome flow, server addition, Discover, and clean quit.

### Setup

1. Quit ModelStatus if it is running.
2. Delete the config file:
   ```
   rm -f ~/Library/Preferences/com.lucasmullikin.ModelStatus.json
   ```
3. Delete all Keychain credentials for the app:
   ```
   security delete-generic-password -s "com.lucasmullikin.ModelStatus.auth" 2>/dev/null; true
   ```
4. Delete the "has shown welcome" UserDefaults key so the welcome window fires:
   ```
   defaults delete com.lucasmullikin.ModelStatus ModelStatus.hasShownWelcome.v3 2>/dev/null; true
   ```

### Steps and Expected Results

**Step 1 — Launch the app.**

- Open `/Applications/ModelStatus.app`.
- **Expected:** The brain icon (🧠) appears in the menu bar within 2 seconds.
- **Expected:** The "Welcome to ModelStatus" window appears automatically within 1 second of the menu bar icon appearing. The window title is "Welcome to ModelStatus". Scrollable body content is visible with headings and numbered steps.
- **Expected:** Three buttons are visible at the bottom: "GitHub" (left), "Open Settings…" (center-left), "Get Started" (right, highlighted as default action).

**Step 2 — Scroll the Welcome window.**

- Drag the scroll bar or use the mouse wheel to scroll the welcome body.
- **Expected:** Content scrolls smoothly. No clipping or text cutoff at top or bottom.

**Step 3 — Dismiss the Welcome window via "Get Started".**

- Click "Get Started".
- **Expected:** Window closes. Menu bar icon remains. No crash.

**Step 4 — Verify the Welcome window does NOT reappear on relaunch.**

- Quit ModelStatus (menu → "Quit ModelStatus").
- Relaunch `/Applications/ModelStatus.app`.
- **Expected:** Menu bar icon appears. Welcome window does NOT appear. The `ModelStatus.hasShownWelcome.v3` key is now set in UserDefaults.

**Step 5 — Open Settings and add a server.**

- Click the 🧠 menu bar icon → "Settings…".
- **Expected:** "ModelStatus Settings" window opens. The Servers table shows exactly one row: "Local" / `http://127.0.0.1:11434` / `Auto-detect` or `Ollama`.
- Click "Add".
- **Expected:** A sheet appears with four fields: Name, URL, Kind popup (defaulting to "Auto-detect"), Authorization header.
- Fill in Name: `Test Server`, URL: `http://127.0.0.1:11434`, leave Kind and Auth blank.
- Click "Add".
- **Expected:** Sheet dismisses. The Servers table now has two rows. The new row shows "Test Server" / `http://127.0.0.1:11434`.

**Step 6 — Verify the new server appears in the menu within 5 seconds.**

- Close the Settings window.
- Wait up to 5 seconds.
- Click the 🧠 icon.
- **Expected:** The menu lists two server sections — "Local" and "Test Server" — each with a status dot (green/yellow/red depending on whether Ollama is running, or "Checking…" if not yet polled).
- **Expected:** Menu opens without perceptible delay.

**Step 7 — Open Settings and run Discover.**

- Click 🧠 → "Settings…".
- Click "Discover…".
- **Expected:** A sheet appears with a spinner and the text "Scanning… Probing local /24 + Tailscale peers for known model-server ports. ~5 seconds." The sheet does NOT time out or freeze the Settings window.
- Wait for the scan to complete (up to 15 seconds).
- **Expected:** The spinner sheet closes. Either:
  - A results sheet appears showing found servers with checkboxes (one per discovered server), "Add Selected" and "Cancel" buttons, **or**
  - A sheet appears saying "No model servers found" with "OK".
- Both outcomes are acceptable; no crash is acceptable.
- If results were found, click "Cancel" (do not add — to keep state clean for the next plans).

**Step 8 — Quit via menu.**

- Click 🧠 → "Quit ModelStatus".
- **Expected:** The app terminates completely. The 🧠 icon disappears from the menu bar within 2 seconds (the 1.5s stop-polling timeout fires and `NSApp.reply(toApplicationShouldTerminate:true)` is called).
- **Expected:** Console.app shows a final log line containing "ModelStatus terminating".
- **Expected:** No zombie ModelStatus process remains (`pgrep ModelStatus` returns nothing).

---

## Test Plan 2 — Stress Test with 20 Servers

**Estimated time:** ~15 minutes  
**Goal:** Verify menu responsiveness, poll cycle completeness, table scroll, and proportional poll reduction when servers are removed.

### Setup

1. Quit ModelStatus if it is running.
2. Craft a config file with 20 entries. Run the following shell script to produce it (it creates 5 real loopback entries on different ports and 15 unreachable LAN IPs):
   ```bash
   python3 - <<'EOF'
   import json, uuid
   instances = []
   # 5 loopback entries (port varies — most will be unreachable unless Ollama is on 11434)
   for port in [11434, 11435, 11436, 1234, 8080]:
       instances.append({"id": str(uuid.uuid4()), "name": f"Local:{port}", "url": f"http://127.0.0.1:{port}", "kind": "auto"})
   # 15 fake LAN IPs that will time out / error quickly
   for i in range(1, 16):
       instances.append({"id": str(uuid.uuid4()), "name": f"LAN-{i}", "url": f"http://192.168.99.{i}:11434", "kind": "auto"})
   config = {
       "instances": instances,
       "pollInterval": 5.0,
       "notifyOnStateChange": False,
       "compactMode": False,
       "verboseLogging": False
   }
   path = os.path.expanduser("~/Library/Preferences/com.lucasmullikin.ModelStatus.json")
   with open(path, "w") as f:
       json.dump(config, f, indent=2)
   print(f"Wrote {len(instances)} instances to {path}")
   EOF
   ```
   (Add `import os` if the script reports a NameError.)
3. Confirm the file exists and has 20 instances:
   ```
   python3 -c "import json; d=json.load(open('$HOME/Library/Preferences/com.lucasmullikin.ModelStatus.json')); print(len(d['instances']), 'instances')"
   ```

### Steps and Expected Results

**Step 1 — Launch the app.**

- Open `/Applications/ModelStatus.app`.
- **Expected:** Menu bar icon appears within 2 seconds.

**Step 2 — Open the menu, verify it is responsive.**

- Start a stopwatch. Click the 🧠 icon.
- **Expected:** The menu opens within 1 second of the click. Menu items for all 20 servers are present (they may say "Checking…" on first open). If any poll has completed, reachable servers show a colored dot; unreachable ones show ✗.
- **Expected:** Scrolling the menu (if it extends past the screen) is smooth, no stutter.

**Step 3 — Verify poll cycle log entries.**

- Wait 30 seconds.
- In Console.app (filter: `com.lucasmullikin.ModelStatus`), search for the string `polling started` or look for per-instance result log lines.
- **Expected:** Log entries show poll results for all 20 instances within each 5-second cycle. There is no instance that never appears in the log across multiple cycles.
- **Expected:** The poll does not drop or skip instances. Count the number of distinct instance names appearing in a single poll window — it must equal 20.

**Step 4 — Open Settings, verify table scroll.**

- Click 🧠 → "Settings…".
- **Expected:** Settings window opens. The Servers table shows all 20 rows.
- Scroll the table up and down.
- **Expected:** Scrolling is smooth. All 20 rows are visible via scroll. No rows are duplicated or missing. Column values (Name, URL, Kind, Auth) are correct for each row.

**Step 5 — Remove 10 servers via Settings.**

- In the Servers table, click the first row, then Shift-click the tenth row to select a range (or click and remove one at a time — either is acceptable).
- Note: the table is single-selection (`allowsMultipleSelection = false`), so remove 10 rows one at a time: select a row, click "Remove", confirm "Remove" in the confirmation sheet, repeat.
- After 10 removals, the table should have 10 rows.
- Close Settings.

**Step 6 — Verify poll cycle count drops proportionally.**

- Wait 30 seconds.
- In Console.app, confirm that poll cycle log output now reflects 10 instances per cycle, not 20.
- **Expected:** The poll loop adjusts immediately after the config change (Settings triggers `onConfigChanged` → monitor restart). No log entries referencing the removed server names appear after the restart.

**Step 7 — Verify menu reflects 10 servers.**

- Click 🧠.
- **Expected:** Exactly 10 server sections are shown. The 10 removed servers are absent.

---

## Test Plan 3 — Permission-Denied Paths

**Estimated time:** ~10 minutes  
**Goal:** Verify graceful degradation when Notification permission, Keychain access, or SMAppService registration is denied.

### Setup

- Restore a clean single-server config (or use whatever config remains from previous plans — the specific server list does not matter here).
- Ensure ModelStatus is running.

---

### 3A — Notification Permission Revoked

**Setup for 3A:**

1. Open System Settings → Notifications.
2. Find ModelStatus in the list. If it does not appear yet, trigger a notification first (step 3A-1 below), then return here.
3. Set ModelStatus notifications to "Off" (or click "Allow Notifications" toggle to disable).

**Steps:**

**Step 3A-1 — Enable notification toggle in Settings.**

- Click 🧠 → "Settings…".
- Check "Notify on reachability change" if it is not already checked.
- Close Settings.

**Step 3A-2 — Trigger a reachability change.**

- If Ollama is running locally: run `pkill ollama` in Terminal to stop it.
- Wait 10–15 seconds for the next poll cycle to detect the server as unreachable.
- Then restart Ollama: `ollama serve &` (or `brew services start ollama`).
- Wait another 10–15 seconds.
- **Expected:** No crash. No macOS notification banner appears (permission is revoked). Console.app shows the reachability-change event was detected but no notification was posted (look for the guard `guard status == .authorized || status == .provisional else { return }` path — the log will not show a notification request being added).
- **Expected:** The menu bar icon updates correctly (dot turns red on unreachable, then green/yellow on recovery), proving the poll loop continues normally.

**Step 3A-3 — Re-enable notifications.**

- Return System Settings → Notifications → ModelStatus → set to "Allow Notifications".
- **Expected:** On the next reachability change, notifications resume.

---

### 3B — Keychain Locked

**Setup for 3B:**

1. Lock the login keychain:
   ```
   security lock-keychain ~/Library/Keychains/login.keychain-db
   ```
   Note: if your keychain path differs, use `security list-keychains` to find it.

**Steps:**

**Step 3B-1 — Attempt to add a server with an auth header.**

- Click 🧠 → "Settings…".
- Click "Add".
- Fill in Name: `AuthTest`, URL: `http://127.0.0.1:11434`, Authorization header: `Bearer test-token-123`.
- Click "Add".
- **Expected:** The sheet dismisses. One of the following occurs:
  - macOS presents a keychain unlock dialog — if so, click "Deny" or cancel.
  - An error alert appears: "Couldn't save credentials for 'AuthTest'" with the text "The Keychain refused the write — possibly because it's locked or this build lacks the right entitlement. The instance was not added."
- **Expected in either case:** The "AuthTest" instance does NOT appear in the Servers table. The config file does NOT contain an entry for AuthTest.
- **Expected:** No crash.

**Step 3B-2 — Unlock keychain and verify normal add works.**

- Unlock the keychain:
  ```
  security unlock-keychain ~/Library/Keychains/login.keychain-db
  ```
  (Enter your macOS password when prompted.)
- Repeat Step 3B-1 but this time allow the keychain access.
- **Expected:** "AuthTest" appears in the Servers table with "🔒 Set" in the Auth column.
- Clean up: select AuthTest and click "Remove".

---

### 3C — SMAppService Registration Outside /Applications

**Setup for 3C:**

1. Copy the app to a non-Applications location:
   ```
   cp -R /Applications/ModelStatus.app ~/Desktop/ModelStatus.app
   ```
2. Quit the running instance (menu → "Quit ModelStatus").
3. Launch the copy from the Desktop: `open ~/Desktop/ModelStatus.app`

**Steps:**

**Step 3C-1 — Try to enable "Start at Login".**

- Click 🧠 → "Settings…".
- Check "Start ModelStatus at login".
- **Expected:** The checkbox is checked briefly, then either:
  - An alert sheet appears: "Couldn't enable Start at Login" with informative text such as "Move ModelStatus.app to /Applications, then try again." or "Approve ModelStatus in System Settings → General → Login Items." (The exact text depends on `LoginItem.failureHint` for the current `SMAppService.mainApp.status`.)
  - The checkbox reverts to unchecked.
- **Expected:** No crash. The alert has an "OK" button. Clicking OK dismisses it.

**Step 3C-2 — Verify the checkbox state is consistent.**

- Close and reopen Settings.
- **Expected:** "Start ModelStatus at login" is unchecked (the setting was not persisted).

**Cleanup:**

- Quit the Desktop copy: menu → "Quit ModelStatus".
- Delete the Desktop copy: `rm -rf ~/Desktop/ModelStatus.app`
- Relaunch from `/Applications`.

---

## Test Plan 4 — Crash Recovery from Corrupted Config

**Estimated time:** ~10 minutes  
**Goal:** Verify the app launches without crashing and recovers to a usable state when the config file is corrupted on disk.

### Setup

1. Launch ModelStatus from `/Applications` and let it run until at least one poll completes (green/yellow/red dot visible).
2. Identify the config path:
   ```
   echo ~/Library/Preferences/com.lucasmullikin.ModelStatus.json
   ```
   Confirm the file exists and is valid JSON:
   ```
   python3 -m json.tool ~/Library/Preferences/com.lucasmullikin.ModelStatus.json > /dev/null && echo OK
   ```

### Steps and Expected Results

**Step 1 — Corrupt the config while the app is running.**

- In Terminal, truncate the config file to 1 byte:
  ```
  truncate -s 1 ~/Library/Preferences/com.lucasmullikin.ModelStatus.json
  ```
- **Expected:** The running app does NOT crash immediately. (ConfigManager only reads on init; in-memory state is unaffected by the file change at runtime.)

**Step 2 — Force-quit ModelStatus.**

- In Terminal:
  ```
  pkill -9 ModelStatus
  ```
- **Expected:** The 🧠 icon disappears from the menu bar.

**Step 3 — Inspect the corrupted file.**

- Confirm the file is indeed 1 byte:
  ```
  wc -c ~/Library/Preferences/com.lucasmullikin.ModelStatus.json
  ```
- **Expected:** Output shows `1`.

**Step 4 — Relaunch the app.**

- Open `/Applications/ModelStatus.app`.
- **Expected:** The app launches without crashing. The 🧠 icon appears in the menu bar within 2 seconds.
- **Expected:** One of the two recovery behaviors occurs:
  - **Behavior A (fallback to default config):** `ConfigManager.init` calls `load(from:)`, which fails to decode the 1-byte file; `loadWithMigration` falls through to `return nil`; the initializer sets `_config = .default` (one instance: "Local" at `http://127.0.0.1:11434`, 5s poll). The menu shows "Local" as the only server. Console.app shows no crash, possibly a decode error log from the JSON decoder.
  - **Behavior B (parse error surfaced in UI):** An error alert is shown to the user indicating config could not be loaded. The user can dismiss it and continues to a working app.
- **Expected:** Either behavior is acceptable. A crash is NOT acceptable.

**Step 5 — Verify the config file is rewritten.**

- After the app has been running for 2 seconds, inspect the config file:
  ```
  python3 -m json.tool ~/Library/Preferences/com.lucasmullikin.ModelStatus.json
  ```
- **Expected:** The file is now valid JSON. `ConfigManager.init` calls `save()` at the end of initialization, which overwrites the corrupted file with the default (or migrated) config.
- **Expected:** File permissions are `0600`:
  ```
  stat -f "%Mp%Lp" ~/Library/Preferences/com.lucasmullikin.ModelStatus.json
  ```
  Output should be `0600`.

**Step 6 — Verify Settings → Add still works.**

- Click 🧠 → "Settings…".
- Click "Add".
- Fill in Name: `Recovery Test`, URL: `http://127.0.0.1:11434`.
- Click "Add".
- **Expected:** "Recovery Test" appears in the Servers table. No error sheet. The config file updates (re-run the `python3 -m json.tool` check to confirm).
- **Expected:** Closing Settings and opening the menu shows "Recovery Test" as a server entry.

**Cleanup:**

- Select "Recovery Test" in Settings and click "Remove" to restore a clean state.

---

## Pass/Fail Summary Checklist

Fill this in after running all four plans.

| Plan | Step | Pass | Fail | Notes |
|------|------|------|------|-------|
| 1 | Welcome window appears on first launch | | | |
| 1 | Welcome window absent on second launch | | | |
| 1 | Add server → appears in menu within 5s | | | |
| 1 | Discover scan completes without crash | | | |
| 1 | Quit removes icon within 2s | | | |
| 2 | Menu opens within 1s with 20 servers | | | |
| 2 | All 20 instances appear in poll log | | | |
| 2 | Settings table scrolls smoothly (20 rows) | | | |
| 2 | Removing 10 servers reduces poll count | | | |
| 3A | No crash when notifications revoked | | | |
| 3A | Menu status dots update correctly | | | |
| 3B | Keychain-locked add shows error alert | | | |
| 3B | Instance NOT persisted on Keychain failure | | | |
| 3C | Start-at-login from ~/Desktop shows error alert | | | |
| 3C | Checkbox reverts on failure | | | |
| 4 | App launches after 1-byte config truncation | | | |
| 4 | Falls back to default config OR shows clear error | | | |
| 4 | Config file rewritten as valid JSON, mode 0600 | | | |
| 4 | Settings → Add works after recovery | | | |

**Submission gate:** All rows in the "Pass" column must be checked before submitting to App Store Connect.
