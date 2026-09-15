# gap-lexer-ownership -- a module cannot own the lexing of a source it claims

The minimal reproducer for the mc gap T4 found, kept so it can be handed to mc and re-run when mc
changes. `sh probes/gap-lexer-ownership/run.sh` prints one line per case and exits 0 only while it
still reproduces. Reported in `docs/plan.md` § 5.

Three bytes and one region are the residue. `source_claim` says a source is the module's, and the
six word registrations then apply to it -- but the core lexes every source before any handler
runs, and it has its own meaning for `'`, for `#` and for `$name`, and no way to hand a region of
raw bytes back.
