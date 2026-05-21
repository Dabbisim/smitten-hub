# Smitten HUB — Project Notes for Claude

Internal sprint-management tool for the Smitten dating-app team. Lets the team run "Top 3 Challenges" sprints: vote on challenges, see auto-suggested teams, run demo days, collect retros. Static site, served from GitHub Pages, Supabase backend.

## Project overview

- **Repo:** `Dabbisim/smitten-hub` (renamed from `top3-challenges` — both URLs redirect)
- **Live URL:** https://dabbisim.github.io/smitten-hub/
- **Audience:** ~3 admins (david@, a@, magnus@smitten.fun) plus team members who follow shared links (voting, reveal, retro)
- **Status:** in active use; recent multi-day refactor moved auth server-side, bundled JS locally, and worked around a Supabase JS deadlock bug

## Tech stack

- **Pure static HTML** — no build step, no framework. Every page is a self-contained `.html` with inline `<style>` and `<script>`.
- **Hosted on GitHub Pages** (auto-deploys on push to `main`).
- **Supabase** — project `cfuilfpgsyxgaizzwlee` (West EU). Free tier — auto-pauses after ~7 days of inactivity (DNS goes NXDOMAIN; "Restore project" in dashboard).
- **supabase-js v2.105.4**, vendored at `vendor/supabase-js.min.js`. Loaded same-origin to avoid CDN block issues.
- **Resend SMTP** for auth emails (configured in Supabase Auth → SMTP Settings). Sender is `onboarding@resend.dev` (Resend default — only delivers to the account owner's email until a custom domain is verified).
- **Fonts** loaded from Google Fonts + Fontshare: DM Sans, Clash Display, Fraunces, Inter.

## File structure

```
.
├── index.html              ← redirects to voting.html
├── voting.html             ← admin-only ranked voting + results dashboard (was index.html)
├── hub.html                ← admin dashboard: list/create/edit/archive/delete sprints
├── admin.html              ← per-sprint admin view: votes table, team builder, retros
├── reveal.html             ← public deck: welcome → N challenge slides → wrap CTA
├── teams.html              ← public team-roster page
├── demo-day.html           ← 3-slide deck: welcome, lineup w/ random pitch order, per-team
│                              presentation timer (7-min pitch + 3-min Q&A), wrap-up
├── show-and-tell.html      ← lighter demo-day clone — just random pitch order, no timer
├── presentation.html       ← static slide deck (no Supabase calls)
├── retro.html              ← public retro submission form (anon insert allowed by RLS)
├── vendor/supabase-js.min.js  ← vendored library (don't load from CDN)
├── supabase/
│   └── migrations/
│       └── 0001_server_side_auth.sql   ← admin_emails, is_admin(), RLS policies, CHECK constraints
└── .claude/
    ├── launch.json         ← local dev server config (python3 http.server :8080)
    ├── settings.json       ← project-shared permission allowlist (committed)
    └── settings.local.json ← user-local overrides (gitignored)
```

Tables: `sprints`, `votes`, `retros`, `admin_emails`. All have RLS enabled.

## Conventions

- **Pages have inline CSS + JS.** No external `.js` or `.css`. New page = copy a similar one, replace the body and `<script>`.
- **Every HTML page must include these cache-busting meta tags** after `<meta charset="UTF-8">`:
  ```html
  <meta http-equiv="Cache-Control" content="no-cache, no-store, must-revalidate">
  <meta http-equiv="Pragma" content="no-cache">
  <meta http-equiv="Expires" content="0">
  ```
  GitHub Pages defaults to a 10-minute cache; without these, every deploy leaves users on stale code.
- **Sprint scoping via URL:** every per-sprint page accepts `?sprint=<uuid>`. Without it, pages fall back to the most recent `status='active'` sprint.
- **Auth is OTP-code, not magic-link.** Supabase emails a 6-digit code (`mailer_otp_length: 6`). The page accepts the code in a `code-input`. Magic-link CLICKING is broken in practice because email security scanners pre-fetch the link and burn the one-time token.
- **Public pages (reveal, demo-day, teams, retro, show-and-tell) MUST create the Supabase client with auth disabled:**
  ```js
  window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false }
  });
  ```
  See *Gotchas* — without this, the page can deadlock against another signed-in tab.
- **Authed pages (voting, hub, admin) cache the access_token in `CURRENT_ACCESS_TOKEN`** and use a small `pg(method, path, body?, prefer?)` helper that runs raw `fetch` against PostgREST. **Do NOT use `db.from()` for queries** — that path deadlocks. `db.auth.*` is fine.
- **`pg()` helper signature** — returns `{ data, error }`, same shape as supabase-js:
  ```js
  await pg('GET',    `sprints?select=*&order=created_at.desc`)
  await pg('PATCH',  `sprints?id=eq.${id}`, { status: 'archived' })
  await pg('POST',   `sprints?select=*`, payload, 'return=representation')
  await pg('DELETE', `votes?sprint_id=eq.${id}`)
  ```
- **Cross-page auth restore.** Each page reads `sb-cfuilfpgsyxgaizzwlee-auth-token` from localStorage on init via `restoreSessionFromStorage()` and calls `handleSession()` with the parsed session. Bypasses the (sometimes wedged) Supabase JS auth client.
- **Per-sprint card buttons in hub.html follow this pattern** — `<a class="alink" href="<page>.html?sprint=${s.id}" target="_blank">`.
- **The Reveal button uses an `onclick` cache-buster** (`window.open(... + '&t=' + Date.now())`) because target="_blank" was reusing stale tabs.

## Design decisions

| Decision | Why |
|---|---|
| **Server-side auth (RLS + `is_admin()`)** | Old client-side `smitten7` password gate was visible in source. Now every authorization runs in Postgres. `admin_emails` table is the source of truth. |
| **OTP code instead of magic-link click** | Email scanners (corporate, antivirus, even some ISP-level) pre-fetch links to scan them, which consumes the one-time token. Code typing can't be pre-fetched. |
| **Resend SMTP via Supabase Auth** | Supabase's built-in email service caps at 2/hour. With Resend SMTP + 30/hr `rate_limit_email_sent`, the testing loop is workable. |
| **`vendor/supabase-js.min.js` (no CDN)** | `cdn.jsdelivr.net` is blocked on some networks/ISPs (especially in some corporate setups), causing whole pages to silently die. Same-origin vendor file always loads. |
| **Voting is admin-only** | User decision in the original auth-migration plan — only the 3 admins vote on challenges. |
| **Public reads stay public** | reveal, teams, retro, demo-day, show-and-tell are share-with-board URLs. RLS allows anonymous SELECT on `sprints` + `votes`. Retros are admin-read-only. |
| **`retros` allows anonymous INSERT** | Team members fill out retros without logging in. RLS `WITH CHECK` validates shape (at least one text field, ≤ 2000 chars each). Hard table-level CHECK constraints back it up. |
| **`pg()` raw-fetch helper instead of supabase-js queries** | The Supabase JS client deadlocks when GoTrueClient sees a conflicting localStorage session (multi-tab). Symptoms: `db.from().select()` hangs forever, no error. Raw fetch with cached `CURRENT_ACCESS_TOKEN` bypasses the auth state machine entirely. |
| **Cache-control meta tags on every page** | Without them, every deploy leaves stale tabs. Many wasted hours of "is the fix deployed?" stem from this. |

## Gotchas and quirks

- **Supabase JS `GoTrueClient` deadlocks.** Open hub.html (signed in) + reveal.html (anonymous client) in the same browser → the second client's first query hangs forever with `"Multiple GoTrueClient instances detected in the same browser context"` in the console. Fix is documented in *Conventions* — disable auth on public pages, use `pg()` on authed pages.
- **`db.auth.getSession()` returns null** when the client is deadlocked, even with a valid session in localStorage. Don't call it from `pg()`. Instead, cache the token in `CURRENT_ACCESS_TOKEN` when `handleSession()` runs.
- **Bypass-permissions mode is server-side gated** on this Anthropic account. The "Bypass" entry isn't in the Cmd+Shift+M menu. No client-side toggle can enable it. Live with `acceptEdits` + a wide allowlist.
- **GitHub Pages caches HTML for 10 min** by default. Many "the fix isn't deployed" reports were actually stale cache. The cache-control meta tags handle this going forward.
- **GitHub Pages last-modified isn't a guarantee** the page is rebuilt. Use `gh api repos/Dabbisim/smitten-hub/pages/builds --jq '.[0]'` to verify build status.
- **The Supabase project pauses after ~7 days of free-tier inactivity.** Symptom: `dig +short cfuilfpgsyxgaizzwlee.supabase.co` returns NXDOMAIN. Fix: dashboard → "Restore project".
- **Resend can only send to david@smitten.fun** until `smitten.fun` is verified in Resend (DNS records needed). Currently sending from `onboarding@resend.dev`, which is restricted to the Resend account owner's email.
- **Email rate limit: 30/hr** — was raised from default 2/hr after wiring up custom SMTP. Without SMTP, max is 2/hr (locked).
- **OTP from `signInWithOtp({email})` is verified with `type: 'email'`** in `verifyOtp` (not `'magiclink'`).
- **`retro_submitted_<sprintId>` localStorage key** gets set on successful retro submission. The "Submit another retro" button on the Thanks screen clears it.
- **Reveal slide template:** `s1` is the placeholder template that gets cloned N times. Its hardcoded text was Sprint 1 challenges originally; now it's neutral `Loading…` so stale states don't show old data.
- **Demo Day timer phases:** `idle` (Start button shown, timer paused at 7:00) → click Start → `pitch` (7:00 → 0) → auto → `qa` (3:00 → 0) → `done` (red alarm pulse). Resetting goes back to `idle`.
- **Per-sprint timer state in demo-day.html lives in module-level `TIMERS` object** keyed by slide id. Shuffle wipes the whole object since position-1 might be a different team after re-shuffle.

## Commands

```bash
# Local dev server (matches .claude/launch.json)
python3 -m http.server 8080
# or via Claude Code preview tooling: preview_start("top3")

# Deploy = just push
git push origin main   # GitHub Pages rebuilds in ~30-60s

# Apply SQL migrations
# Open supabase/migrations/0001_server_side_auth.sql, copy a section, paste
# into Supabase Dashboard → SQL Editor → Run. OR use Management API:
SUPABASE_TOKEN=$(security find-generic-password -s "Supabase CLI" -w | sed 's/^go-keyring-base64://' | base64 -d)
curl -X POST "https://api.supabase.com/v1/projects/cfuilfpgsyxgaizzwlee/database/query" \
  -H "Authorization: Bearer $SUPABASE_TOKEN" -H "Content-Type: application/json" \
  --data "$(jq -n --arg q '<sql here>' '{query:$q}')"

# Generate a one-shot magic link for testing (bypasses email)
SECRET=$(curl -sS "https://api.supabase.com/v1/projects/cfuilfpgsyxgaizzwlee/api-keys?reveal=true" \
  -H "Authorization: Bearer $SUPABASE_TOKEN" | jq -r '.[] | select(.name=="default" and .type=="secret") | .api_key')
curl -X POST "https://cfuilfpgsyxgaizzwlee.supabase.co/auth/v1/admin/generate_link" \
  -H "apikey: $SECRET" -H "Authorization: Bearer $SECRET" -H "Content-Type: application/json" \
  --data '{"type":"magiclink","email":"david@smitten.fun","redirect_to":"https://dabbisim.github.io/smitten-hub/hub.html"}' \
  | jq -r '.email_otp'   # 6-digit code for direct entry into the page's code-input
```

There are no tests, no linter, no build. Verification is `python3 -m http.server` + open the page.

## Work in progress / next up

- **Verify `smitten.fun` in Resend** so a@ and magnus@ can also receive auth emails. Requires DNS records (SPF/DKIM) on whatever DNS provider hosts `smitten.fun`. Once verified, update Supabase Auth `smtp_admin_email` to `noreply@smitten.fun`.
- **admin.html realtime channel** (`db.channel('admin-votes')`) still uses the raw Supabase JS client. If live vote updates stop working, convert to a polling refresh via `pg()`.

## Things to avoid (lessons learned)

- **Do NOT use `db.from()` for queries.** Use `pg()` raw-fetch helper. The Supabase JS query builder deadlocks under multi-tab auth. This bit us for hours.
- **Do NOT call `db.auth.getSession()` from helpers.** Same deadlock. Cache the token in `CURRENT_ACCESS_TOKEN` instead.
- **Do NOT load supabase-js (or any other library) from a CDN.** Vendor it. CDNs get blocked on some networks and the failures look identical to bugs.
- **Do NOT suggest magic-link clicks as primary auth UX.** Some email scanners pre-fetch the link and burn the token. Code-typing is the only reliable path.
- **Do NOT try to enable `bypassPermissions` permission mode** in Claude Code settings — it's server-side gated on this Anthropic account. The option doesn't appear in the mode picker. Live with `acceptEdits` + a wide allowlist in `~/.claude/settings.json`.
- **Do NOT hardcode sprint-specific copy** (titles, deadlines, "Three bold bets") in static HTML. Default to neutral placeholders (`Loading…`, `&nbsp;`) and let JS populate from `sprint.slides`. We had Sprint 1's text leak into Sprint 2 because the JS data load was racing or failing silently.
- **Do NOT trust `setTimeout` to defer scroll-to-anchor on initial load** without ensuring the target element exists. Wait for the data load that creates it (or use `scroll-margin-top` on the anchor to handle dynamic content).
- **Do NOT remove the deny rules** in `~/.claude/settings.json` (`rm -rf /`, etc.). Cheap insurance against a runaway prompt.
- **Do NOT use `eq`/`single` builder chains** if you switch a page from `db.from()` to `pg()` — write the PostgREST URL directly (`?id=eq.X`, `?select=*&limit=1`).
- **Do NOT close the original session.json without backing up** — Claude Code's session metadata file got overwritten by the desktop app at launch, which caused multiple "is my fix in place?" loops.
