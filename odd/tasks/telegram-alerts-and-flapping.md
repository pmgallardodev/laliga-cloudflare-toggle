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

- [x] T6: validate the feed. Require an HTTP 2xx, a non-empty body, `.data` as an array, string `ip`/`isp`,
      a nullable `description`, and `stateChanges` as an array of objects. Any invalid response follows the
      unavailable-feed timeout path, and no jq call can crash the run.
- [x] T7: CIDR correctness. Do exact numeric membership for every published Cloudflare IPv4/IPv6 range,
      with boundary tests.
- [x] T8: numeric env parsing. Base 10 with bounds for `MIN_CLEAR_MINUTES`, `MAX_DISABLED_HOURS`,
      `CHECK_INTERVAL` and persisted epochs (`08` must work).
- [x] T9: timestamps. Parse legacy ISO `...Z` disabled_at as UTC on GNU, BusyBox and BSD; an unparseable
      value must not wait forever.
- [x] T10: name handling. Comparisons are case-insensitive and ignore a trailing dot (protected domains,
      scope, state keys).
- [x] T11: restore PATCH sends only `{"proxied": true}` (and disable only `{"proxied": false}`), so a
      rename is never reverted.
- [x] T12: write-ahead state. Record the intent before the PATCH and reconcile the real record state on the
      next run (ambiguous PATCH, crash, or log failure). A log write failure must not abort bookkeeping.
- [x] T13: corrupt state. Quarantine the file, log ERROR and alert; never treat it as `[]` and never delete
      the support files.
- [x] T14: pagination of dns_records.
- [x] T15: hysteresis. A feed outage resets the clear timer (only consecutive healthy, clear checks count).
- [x] T16: per-record restore accounting and alerts (a partial restore is alerted).
- [x] T17: candidate discovery covers proxied subdomains when the apex has no Cloudflare IPs (bounded).
- [x] T18: partial mitigation warnings. A CNAME to another zone, or a same-name read-only proxied record,
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
- T6 `<T6>` fix(feed): validate hayahora responses. `feed_is_valid` (jq -se, one object, typed fields) RED: `command not found` (13 unit checks failed / 4 passed by accident), integration 18 of 23 failed (exit 5 on `{"error":..}`, data null/string, object stateChanges, null description; empty body treated as healthy). GREEN: unit 67/0, integration 43/0 on bash 5 and 3.2. Feed fetched with `curl -sf` so HTTP >= 400 is unavailable; null description tolerated in the broad check. shellcheck clean, `bash -n` ok, scratch harness 23/0.
- T7 `<T7>` fix(cidr): exact numeric membership. RED: unit aborted (`CF_IPV4_RANGES: unbound variable`), integration `cidr-origin-not-cloudflare` failed (www PATCHed for a 108.162.1.x origin). GREEN: unit 169/0 (first/last/just-outside for all 15 v4 and 7 v6 ranges, 104.16/13 and 104.24/14 adjacency handled), integration 44/0, both shells. Single list `CF_IPV4_RANGES`/`CF_IPV6_RANGES`; `ipv4_parse`/`ipv6_parse` without subshells; `ipv6_prefix48` reuses `ipv6_parse`. shellcheck clean, scratch harness 23/0.
- T8 `<T8>` (with T9) fix(config): `parse_uint` (base 10, <=15 digits, bounds). MIN_CLEAR_MINUTES 0-10080, MAX_DISABLED_HOURS 1-720 (invalid -> WARN and default); clear marks and numeric disabled_at go through it. RED: unit `command not found`; integration `minutes-08` 3 fails (bash 5 and 3.2), `max-hours-invalid` failed. GREEN: unit 198/0, integration 57/0 on both shells.
- T9 `<T8>` pure-bash `iso_to_epoch` (days_from_civil, Z/offset/fraction, no `date` dependency, so GNU/BusyBox/BSD behave the same; BusyBox not run locally) and `epoch_of`. Timeout uses the oldest entry of the domain; an unreadable disabled_at logs ERROR and counts as expired. RED: TZ=Europe/Madrid restored at 11.5 h; garbage timestamp waited forever; oldest entry ignored. GREEN as above.
- T10 `<T10>` (with T11) fix(names): `canon_name` and `CANON_JQ` (lowercase, trimmed, no trailing dot) for DOMAINS, PROTECTED_DOMAINS, record names, state matching and the keys of the ips/clear files (legacy keys migrate on read). RED: unit `command not found`; integration 5 fails (`PROTECTED_DOMAINS=EXAMPLE.TEST.` was PATCHed, mixed-case DOMAINS/records/legacy state not matched). GREEN: unit 202/0, integration 65/0 on both shells.
- T11 `<T10>` PATCH bodies are the literals `{"proxied":false}` and `{"proxied":true}`; a renamed record logs WARN and keeps its new name. RED: 3 fails (full body sent, rename reverted). GREEN as above.
- T12 `<T12>` fix(state): write-ahead intent. The state entry is written with `status: pending` before the PATCH and confirmed after it; a 4xx rejection removes it; no response (curl 28/5xx) keeps it. `reconcile_pending` GETs pending records at the start of each domain: grey -> confirmed and alerted, proxied -> dropped (re-disabled if still blocked), 404/81044 -> dropped. `cf_api` now returns via `CF_BODY`/`CF_HTTP` (no stdout), `log` no longer uses `tee` and never aborts. RED: 11 of 13 checks failed (ambiguous PATCH left an untracked grey record; a read-only log file exited 1 before the state write). GREEN: integration 78/0 on both shells, unit 202/0, scratch harness 23/0.
- T13 `<T13>` fix(state): `quarantine_if_invalid` checks state (array of objects with string record_id), ips (legacy array or object of string arrays) and clear (object) once at start. Invalid -> moved to `<file>.corrupt-<epoch>`, ERROR, one Telegram alert (also on the feed-down early exit) naming the domains that still have saved IPs. Documented behaviour: no automatic reconciliation of lost ownership; while a `proxy_disabled.json.corrupt-*` exists the support files are never deleted; a corrupt ips/clear file does not stop restoring the parsable state. DRY_RUN only logs. RED: 10 of 13 checks failed (state read as [], all three files deleted). GREEN: integration 92/0 on both shells.
- T14 `<T14>` fix(cloudflare): `cf_list_records` follows `result_info.total_pages` (page 1 is `?per_page=100`, then `&page=N`, cap 50 pages, any page failure fails the listing), cached per domain iteration. RED: 3 fails (only 100 of 101 PATCHed, page 2 never requested). GREEN: integration 95/0 on both shells, unit 202/0, scratch harness 23/0, shellcheck clean.
- T15 `<T15>` (with T16) fix(restore): on the feed-down path the clear mark of each domain with state is deleted (not in DRY_RUN), so only consecutive healthy clear checks count. RED: 3 fails (restored on the first run after a 55-minute outage). GREEN: integration 106/0 both shells. Scratch harness: 22/1, the failing check `run8 hayahora caida no toca clear` asserts the pre-T15 behaviour and is now obsolete by design.
- T16 `<T15>` each restored (or already proxied) record is counted and listed as it completes; the REHABILITADO alert adds a "Restauracion parcial" section with the records still grey; a GET 404/81044 logs "ya no existe ... Se da por resuelto" and drops the entry. RED: partial restore sent no alert; a deleted record blocked the domain forever. GREEN as above.
- T17 `<T17>` (with T18) feat(detect): when the apex yields no Cloudflare IP, `resolve_child_candidates` resolves the zone's proxied hostnames in scope (no wildcards, at most 10, 7 dig queries each: system A/AAAA plus ECS A per ISP, so <= 70 queries, only in this case); the listing is cached for disable_domain. RED: grey apex with blocked proxied www -> no Cloudflare call, no PATCH. GREEN: integration 116/0 both shells; scratch harness 22/1 (obsolete run8 check, see T15).
- T18 `<T17>` `partial_mitigation_warnings`: proxied CNAME whose target is outside the managed domain, and read-only proxied records in scope; logged as WARN [PARCIAL] and added to the DISABLED alert under "Mitigacion parcial" (only for domains with new disables; protected names skipped). RED: 3 fails (no warning). GREEN as above.
