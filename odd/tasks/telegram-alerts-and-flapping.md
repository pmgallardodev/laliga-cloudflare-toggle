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
- [x] T3: alert only on newly disabled records, and summarize the reasons (a capped number of
      matches per domain, then "+N more").
- [x] T4: add a restore hysteresis. `MIN_CLEAR_MINUTES` (default 15) is how long a domain must
      stay clear in consecutive checks before it is restored. A new block resets the clear timer.
- [x] T5: document the new options in `README.md` and `.env.example`.

### Round 2: Codex review findings (gpt-6.1-sol, report `/private/tmp/laliga-audit.2WjVm2/REPORT.md`)

The user authorized fixing all findings, then commit and push of this branch (2026-11-08).

- [ ] T6: validate the feed. Require an HTTP 2xx, a non-empty body, `.data` as an array, string `ip`/`isp`,
      a nullable `description`, and `stateChanges` as an array of objects. Any invalid response follows the
      unavailable-feed timeout path, and no jq call can crash the run.
- [ ] T7: CIDR correctness. Do exact numeric membership for every published Cloudflare IPv4/IPv6 range,
      with boundary tests.
- [ ] T8: numeric env parsing. Base 10 with bounds for `MIN_CLEAR_MINUTES`, `MAX_DISABLED_HOURS`,
      `CHECK_INTERVAL` and persisted epochs (`08` must work).
- [ ] T9: timestamps. Parse legacy ISO `...Z` disabled_at as UTC on GNU, BusyBox and BSD; an unparseable
      value must not wait forever.
- [ ] T10: name handling. Comparisons are case-insensitive and ignore a trailing dot (protected domains,
      scope, state keys).
- [ ] T11: restore PATCH sends only `{"proxied": true}` (and disable only `{"proxied": false}`), so a
      rename is never reverted.
- [ ] T12: write-ahead state. Record the intent before the PATCH and reconcile the real record state on the
      next run (ambiguous PATCH, crash, or log failure). A log write failure must not abort bookkeeping.
- [ ] T13: corrupt state. Quarantine the file, log ERROR and alert; never treat it as `[]` and never delete
      the support files.
- [ ] T14: pagination of dns_records.
- [ ] T15: hysteresis. A feed outage resets the clear timer (only consecutive healthy, clear checks count).
- [ ] T16: per-record restore accounting and alerts (a partial restore is alerted).
- [ ] T17: candidate discovery covers proxied subdomains when the apex has no Cloudflare IPs (bounded).
- [ ] T18: partial mitigation warnings. A CNAME to another zone, or a same-name read-only proxied record,
      is reported in the alert.
- [ ] T19: notification outbox. Failed or 429 alerts persist and are retried with deduplication.
- [ ] T20: atomic lock (`mkdir` or `flock`) and a unique tmp file for `atomic_write`.
- [ ] T21: PID 1 signals. Trap TERM/INT in entrypoint.sh, wait for the child, then exit.
- [ ] T22: bounded log (size-based rotation).
- [ ] T23: integration tests in the repo (stub curl/dig) that cover the scenarios above; update the docs.

## Acceptance criteria

- Pure helpers (truncation, reason summary, restore decision) have tests in
  `tests/test-ip-match.sh`, and `bash tests/test-ip-match.sh` passes.
- `shellcheck -S warning` reports no new warnings.
- `bash -n` succeeds for every script.

## Route

- Delegated direct: one writer, because 2 or more non-trivial files change.

## Progress

(updated per task with commit ids)

Next step: parent review of the branch; push and PR remain the user's decision.

- T1 (delegated writer) `f72e20f` fix(cloudflare): skip read-only records and log API errors.
  Checks: tests 27 ok / 0 fallos; shellcheck only the 2 pre-existing warnings (SC1090, SC2034);
  `bash -n` ok. Stub harness: read-only AAAA never PATCHed (RED on base, GREEN after); HTTP 400
  now logs `[{"code":1043,...}]`.
- T2 (delegated writer) `d35a04e` fix(telegram): bound message length and log rejected notifications. `truncate_text`
  (jq, counts Unicode characters) RED: `command not found`; GREEN: 36 ok / 0 fallos. Variable
  message parts are cut in raw form before `html_escape`, so no entity is ever split; budget
  3500 characters (half per part when there are two). `notify_telegram` logs `ERROR` with
  `.description` when `ok != true`; harness run with `ok:false` logged it and exited 0.
  shellcheck: only the 2 pre-existing warnings; `bash -n` ok.
- T3 (delegated writer) `e798591` fix(alerts): notify only new disables with a summarized reason. `summarize_matches`
  RED: `command not found` (5 of 6 new checks failed); GREEN: 42 ok / 0 fallos. DISABLED alert
  lists only records disabled in this run plus the state total; a reason is added only for
  domains with a new disable. Harness: a second blocked domain alerts only itself, a still-blocked
  run sends no DISABLED alert, 150 matches summarize to "+147 mas". shellcheck: only the 2
  pre-existing warnings; `bash -n` ok.
- T4 (delegated writer) `e5278c6` feat(restore): wait MIN_CLEAR_MINUTES of clear checks before restoring. `restore_due` RED:
  4 of 8 new checks failed (`command not found`); GREEN: 50 ok / 0 fallos. Clear marks live in
  `${STATE_FILE%.json}_clear.json`, written with `atomic_write`, reset on a new block, deleted
  after a full restore and by the end-of-run cleanup. Harness (23/23): one clear run with
  `MIN_CLEAR_MINUTES=15` does not restore; a 20-minute-old mark restores; `0` restores at once;
  DRY_RUN writes no mark; a down feed leaves marks untouched and keeps the timeout path.
  shellcheck: only the 2 pre-existing warnings; `bash -n` ok.
- T5 (delegated writer) `508e985` docs: document MIN_CLEAR_MINUTES, alert format and read-only records. README:
  hysteresis section, read-only records, new failure rows, clear file, new alert format.
  `.env.example`: `MIN_CLEAR_MINUTES=15`. Passive docs: structural readback only (no RED/GREEN);
  tests 50 ok / 0 fallos, shellcheck only the 2 pre-existing warnings, `bash -n` ok.

Round 2 (delegated writer, one bounded writer; route: delegated direct because 2+ non-trivial files
change). Each entry lists the commit and the observed checks.

- T23 part 1 (harness): `tests/test-integration.sh` with stub `curl`, `dig` and `date` in
  `tests/integration/bin`, and `tests/run-all.sh` (bash 5 and `/bin/bash` 3.2). Covers T1-T4 with the
  current code: 20 ok / 0 fallos on both shells (GREEN by design; it pins existing behaviour). Also
  silences the 2 pre-existing shellcheck warnings with directives (SC1090 `.env`, SC2034).
