# Feature: telegram-alerts-and-flapping

Branch: `fix/telegram-alerts-and-flapping` (base: `main` @ 44b0749)

## Objective

Make disable alerts reliable and stop the proxy from flapping during LaLiga blocks.

## Problem (production evidence, hermes-vps, 2026-11-07, times in UTC)

1. **Disable alerts are lost without any log entry.** Every run that is still blocked calls
   `disable_domain` again and appends to `disable_reasons`. The 17:31 run carried 144 matches
   (~6.6 KB), above Telegram's 4096-character limit. Telegram answered HTTP 400, and
   `notify_telegram` discarded the response, so nothing was logged. Only the 17:14 alert arrived.
2. **The proxy flaps.** The `/24` rule matches neighbour Cloudflare IPs, and hayahora toggled those
   neighbours between runs (e.g. Vodafone 104.21.13.229 vs our 104.21.13.225). With no hysteresis,
   looksyhq.com went through a disable/restore cycle six times between 17:37 and 23:15.
3. **One record fails on every run.** `AAAA media.eskubilse.com` (`100::`, Worker-managed,
   `meta.read_only: true`) returns HTTP 400 (code 1043) on each run. `cf_api` logs the status code
   but not Cloudflare's error.

## Scope

- `toggle-proxy.sh`, `lib/ip-match.sh`, `tests/test-ip-match.sh`, `README.md`, `.env.example`.
- Out of scope: log rotation, write-ahead state, PID 1 signal handling (review items, not
  authorized here).

## Tasks

- [x] T1: skip records where `meta.read_only == true`, and log the Cloudflare `errors` body on
      non-2xx responses.
- [x] T2: make Telegram delivery checked and bounded. Truncate text to fit the 4096-character
      limit, and log `ERROR` when the API answers `ok != true`.
- [ ] T3: alert only on newly disabled records, and summarize the reasons (a capped number of
      matches per domain, then "+N more").
- [ ] T4: add a restore hysteresis. `MIN_CLEAR_MINUTES` (default 15) is how long a domain must
      stay clear in consecutive checks before it is restored. A new block resets the clear timer.
- [ ] T5: document the new options in `README.md` and `.env.example`.

## Acceptance criteria

- Pure helpers (truncation, reason summary, restore decision) have tests in
  `tests/test-ip-match.sh`, and `bash tests/test-ip-match.sh` passes.
- `shellcheck -S warning` reports no new warnings.
- `bash -n` succeeds for every script.

## Route

- Delegated direct: one writer, because 2 or more non-trivial files change.

## Progress

(updated per task with commit ids)

- T1 (delegated writer) `f72e20f` fix(cloudflare): skip read-only records and log API errors.
  Checks: tests 27 ok / 0 fallos; shellcheck only the 2 pre-existing warnings (SC1090, SC2034);
  `bash -n` ok. Stub harness: read-only AAAA never PATCHed (RED on base, GREEN after); HTTP 400
  now logs `[{"code":1043,...}]`.
- T2 (delegated writer) feat(telegram) commit, hash recorded in the T3 entry. `truncate_text`
  (jq, counts Unicode characters) RED: `command not found`; GREEN: 36 ok / 0 fallos. Variable
  message parts are cut in raw form before `html_escape`, so no entity is ever split; budget
  3500 characters (half per part when there are two). `notify_telegram` logs `ERROR` with
  `.description` when `ok != true`; harness run with `ok:false` logged it and exited 0.
  shellcheck: only the 2 pre-existing warnings; `bash -n` ok.
