# LAUNCH-SCHEDULE — v0.2.0

Day-by-day plan for the v0.2.0 awareness push. Drafts live in [`launch-posts.md`](launch-posts.md). Don't post out of order — each step builds momentum/social proof for the next.

**Why this matters:** first-hour velocity on Reddit + HN determines whether a post escapes "new" and lands on a feed where humans actually see it. Peak windows + first-24hr comment engagement are not optional polish — they're the difference between 0 and 1000 stars.

---

## Day 1 — Tuesday  ← **r/LocalLLaMA**

| When | What |
|---|---|
| Mon 8pm ET (night before) | Final eyeball on the post text. Confirm screenshot embedded correctly. Make sure the brew install line works on a clean machine if you can spot-check. |
| **Tue 10:00 AM ET** | **Post to r/LocalLLaMA.** Sweet spot for both EU evening + US morning. |
| Tue 10:00 AM – noon ET | Sit on Reddit. Reply to every comment within ≤30 min. The first 5–10 comments determine if the post stays alive. |
| Tue 12–6pm ET | Check every 30–60 min. Reply to anything thoughtful with substance, not "thanks!" |
| Tue 6pm ET | **Optional:** Twitter/X thread (drafts in launch-posts.md). Don't burn the X angle if your X following is small — could read as "trying too hard." |
| Tue 11pm ET | Final check. Note the upvote/comment count for tomorrow's HN framing. |

**Success looks like:** ≥50 upvotes, ≥20 comments, no hostile pile-on. Hot take: r/LocalLLaMA is one of the friendlier communities for tools like this — bad posts get ignored, not torched.

---

## Day 2 — Wednesday  ← **Show HN**

| When | What |
|---|---|
| Tue 11pm ET (night before) | Re-read the Show HN body. Trim any sentence that doesn't earn its space. HN is brutal about flabby text. |
| **Wed 9:00 AM ET** | **Post Show HN.** Title MUST start with `Show HN:`. Submit URL = GitHub repo (not a blog post). HN dislikes meta-content. |
| Wed 9:00 AM – noon ET | First hour is everything. Sit on the page. Reply to every comment under 5 min. The "second flag rule" — if 3 people flag you in the first hour, you're toast. Most flags come from low-effort comments getting low-effort replies. |
| Wed noon – 5pm ET | Even if the post is moving slowly, keep replying. HN voters re-evaluate over the day. |
| Wed evening | If it makes the front page, expect a brief traffic spike. The Homebrew tap will be hit; the GitHub stars counter starts moving. Brace for issues being filed — even bad ones. |

**Common HN feedback to be ready for:**
- "Why not just curl /api/ps in a tmux pane?" → answer: it's about *aggregate* multi-server view + the menu-bar always-on availability + the per-process telemetry.
- "Electron when?" → "Pure AppKit. ~1.4 MB binary. No deps." End of conversation.
- "What's the business model?" → honest answer: direct download free forever, future App Store version $4.99 to fund development.
- "Why unsigned?" → "Apple Developer enrollment in progress; until then `xattr -dr com.apple.quarantine` is the install step."
- "Where's the Linux/Windows version?" → "Not yet. Sorry."

**Success looks like:** front page for 4+ hours, ≥100 upvotes, GitHub stars cross 200.

---

## Day 3 — Thursday  ← **r/macapps**

| When | What |
|---|---|
| **Thu 11:00 AM ET** | **Post to r/macapps.** Smaller community, more design-focused. Drop the "discovery details" paragraph; lead with "menu bar tool" angle. |
| Thu noon – 6pm ET | Lower-velocity engagement. Reply within 2 hours is fine. r/macapps is friendly. |

**Social proof from earlier in the week is now available:** if the LocalLLaMA or HN posts went well, you can mention "got X stars in the first 48 hours" in the r/macapps reply chain — but never in the post body itself. That's how indie devs do it without coming off as bragging.

---

## Day 4+ — Awesome-list PRs (slow burn)

These are SEO/discoverability plays, not traffic spikes. File once, forget. Each one drips users for months/years.

| Target list | Section | Already PR'd? |
|---|---|---|
| jaywcjlove/awesome-mac | Applications → Menu Bar Tools | TODO |
| iCHAIT/awesome-macOS | Productivity | TODO |
| Hannibal046/Awesome-LLM | Tooling | TODO |

**PR template lives in launch-posts.md.** I can file these in batch when you say go — they don't need timing, just per-PR authorization (standing rule).

---

## Day 7+ — Ollama PR follow-up

The `ollama/ollama` PR #16291 is still open with a v0.2 refinement comment from 2026-05-26. If maintainers haven't replied by Day 7:

- One polite ping comment ("Hey, just checking — anything I can do to move this forward?")
- If silent another 14 days: leave the PR open. Don't close. Don't re-open elsewhere. Patience plays well in OSS.

---

## What to NOT do

- ❌ **Don't cross-post Reddit subs same-day.** Stagger by at least 24 hours.
- ❌ **Don't post the SAME body text to multiple subs.** Each post needs different framing for that audience.
- ❌ **Don't reply with "thanks!" or "great point!" — those tank the comment ratio that Reddit/HN use as a quality signal.**
- ❌ **Don't run a Twitter giveaway / contest.** Apple/HN/Reddit all penalize that.
- ❌ **Don't @mention Apple employees on Twitter to "get noticed."** Backfires every time.
- ❌ **Don't post in r/programming or r/swift on launch week.** Those subs are tool-skeptical and the audience overlap is low. Save for v1.0 + App Store launch.

---

## Metrics worth tracking (not vanity)

- GitHub stars: vanity but useful for App Store description ("100+ stars on GitHub")
- Brew tap installs: real signal — `gh api /repos/lucasmullikin/homebrew-tap/traffic/clones` shows clones-per-day if you ever scripted install via clone, otherwise you have to ask brew analytics
- Diagnostic bundles received (via GitHub issues): real signal of who's actually using it + hitting edge cases
- Reddit upvotes ratio (upvotes/views): >5% means it landed; <2% means dud
- HN front-page minutes: anything ≥120 mins is a win

---

## After launch week — connecting to v1.0

The v0.2 launch is essentially a **beta-test surface** for the App Store v1.0 submission:

1. **Bug reports → issue tracker → fix list for v1.0**
2. **"It crashed when..." → repro + fix BEFORE App Store reviewer sees it** (much better to fail in public on GitHub than at App Review)
3. **"Does it support X server?" → roadmap input for v1.0 / v1.1**
4. **Brew tap install metrics → demand signal for the paid App Store SKU**

v0.2 is your free, direct-download beta-tester pool. v1.0 is your sandboxed, $4.99, App-Store-distributed product. Both ship from the same codebase via the `MODELSTATUS_APP_STORE` compile flag.

The launch week's job is to **convert your enthusiast audience into the v1.0 review-cycle reporter pool.** Bug reports + edge cases now = no surprises at App Review later.
