# mc-php -- operating rules

Read `docs/plan.md` first. This repository is a CONSUMER of mc 1.0.0 (frozen surface): it never
edits mc's `src/`; a surface gap is reported to mc with a reproducer, never patched around here.

- A `.php` file is PHP: it must run under `php` unchanged. No dialect.
- The oracle is php-src's `.phpt` corpus under `php` and under the mc-php build; every claim
  carries its green/total number.
- Comments, messages and docs in English; ASCII identifiers; no emojis.
- Every probe under `probes/` prints one number and exits 0 only when it measured it.
- One agent at a time; measurements before design; a decision in `docs/plan.md` § 3 is taken only
  by the probe that decides it.

## State
- 2026-09-15: repository created; plan and test grid written; no probe run yet.
