# Adversarial audit and repairs — 2026-10-13

The previous 100-case suite passed on a fresh build but missed the failures
below. Independent lanes examined copied real histories, parser and pricing
boundaries, filesystem races, and source behavior against the preserved
`zig` branch (`9e060d9a`) and the adapted Zig 0.17 reference. A separate reviewer
then reviewed the repairs and ran independent probes.

## Confirmed findings

All listed fixes are application or reference changes. Habu release
`c53b4d2c` and the preserved original Zig source were left unchanged.

| Severity | Failure before repair | Reproducer and resolution |
|---|---|---|
| P2 | Missing, null, or empty session IDs aborted sessions text with exit 67 after its title; Zig printed the complete table. | Put `{"timestamp":"2026-01-02T03:04:05Z","input_tokens":1}` in `projects/p/x.jsonl`, then run `sessions`. The empty text buffer now supplies a valid pointer with length zero. Permanent `empty-session-*` cases cover JSON and text. |
| P2 | A closed pipe reader terminated Habu with SIGPIPE; Zig help exited 0 and reports exited 1 with `error: WriteFailed`. | Run help or a report with stdout connected to a pipe whose reader is closed. The application now applies the existing `FD-NOSIGPIPE!` API to stdout and diagnostic stderr, preserving exit status even when both streams are unavailable. Permanent `broken-stdout-*` cases assert expected errors. |
| P2 | True sessions reports scaled quadratically: 20,000 sessions took about 10.6–10.9 s; 100,000 exceeded the audit's 20 s limit. | One synthetic file with distinct session IDs, invoked with `sessions --json`. Row and membership lookups now use hash indexes, text rendering follows per-row membership chains, and sorting is O(n log n) with explicit stable tie ranks. Permanent 20k JSON and 2k text cases verify exact order and totals. |
| P3 | Some large finite costs differed by one cent in JSON. | Explicit `costUSD:100000000000000.125` printed `.13` instead of Zig's `.12`; a computed u64 price also reproduced it. The bounded binary64 formatting correction handles the shortest-decimal midpoint cases that affect cents. No arbitrary-precision numeric machinery was added. |
| P3 | Negative date conversion could differ after a wrapped `u8` day; the original also read beyond its month table for month 14+. | `1970-01-00T00:00:01Z` with timezone `-01:00`, or month 99. Both maintained implementations now reject month >13 and skip adjusted timestamps below -86400 in date-grouped reports. Sessions still ignore timezone. These are documented safety changes to undefined or unsafe original behavior, not new calendar normalization. |
| P2 | The adapted Zig 0.17 walker leaked open descendant directories on an early walk error and could silently miss a later valid root. | Twelve unreadable nested roots followed by one valid root, with `RLIMIT_NOFILE=24`. The reference explicitly leaves remaining walker entries before deinit. The original Zig 0.15 walker already closed these handles; this was an adaptation regression. |

The rounding correction is limited by binary64 spacing: lower even shortest
tenths can affect cents at exponents 49/50 (`.25`), and shortest hundredths at
46/47 (`.125`, `.625`). Finer shortest-decimal ties cannot cross the cent
rounding threshold. The independent reviewer checked boundary neighbors,
both signs, exponent transitions, and seeded finite bit patterns.

## Coverage

- Parser/pricing lane: 1,230 synthetic fixtures and 2,561 paired comparisons,
  covering raw and malformed fields, duplicates, Unicode, EOF and line
  boundaries, zero/negative/overflowing counters, model prefixes, cache
  accounting, explicit costs, dates/timezones, JSON/ANSI, and ties.
- History lane: 18 explicitly authorized local files copied privately
  (61.22 MiB); 110 deterministic comparisons plus aggregate, repeatability,
  and HOME-discovery checks. Source and fixture digests remained unchanged.
  Private history copies were deleted; no log contents are in this repository.
- Filesystem lane: 19 static cases; missing/unreadable roots, hidden paths,
  symlinks/cycles, hardlinks, FIFO exclusion, deep/long paths and duplicates.
  Eight append/truncate runs and 20 atomic replacement runs retained valid
  initial data. Nine-file deterministic cases matched; ten/24-file Zig runs
  varied in order while retaining complete rows and totals.
- Fresh repaired builds: **131/131** against each of the stripped-small and
  smallest Zig configurations. This includes inclusive 512 MiB cap−1/cap/cap+1,
  live append retention, output errors, high-cardinality session order,
  malformed date guards, rounding, and descriptor exhaustion.
- Independent repair review: 950 monetary values and 72 date-boundary
  comparisons, eight integrated indexing and ordering probes, and a 45-case stdout/stderr failure matrix. See the
  saved review result in [evidence.md](evidence.md).

Every target invocation used synthetic HOME and bounded fixture roots. HOME
discovery cases intentionally omitted `--data-dir` within that synthetic HOME.
The CLI has no persisted application state; tests also checked fixture
integrity, exit status, stdout, stderr, and computed totals.

## Readiness and limits

The confirmed deterministic regressions above are repaired and covered by
fresh tests and independent review. This is evidence for the tested macOS
arm64 CLI, not proof over every input or filesystem schedule. There was no
installed original Zig executable or Zig 0.15 compiler available; the original
was source-reviewed and the runnable reference uses Zig 0.17. Linux lowering
of the pipe API was source-checked but not executed.

The raw field scanner, unescaped JSON strings, permissive command parsing,
historical pricing formula, and bounded numeric behavior remain intentional.
Zig's threaded ordering is schedule-dependent at ten or more files; Habu's
serial scanner cannot reproduce every such order. Append/race assertions
cover retention and integrity rather than identical concurrent snapshots.
Runtime, memory, size, and timing provenance are reported separately in
[evidence.md](evidence.md). No installed command was replaced and nothing was
pushed by this repair task.
