<?php
// A declared scalar RETURN is checked: php's own TypeError, php's own
// sentence (docs/plan.md § 7). It was a bare conversion, and the first
// function below answered int(0).
function r_str(): int { return "x"; }
function r_num(): int { $s = "42"; return $s; }
function r_arr(): int { return [1]; }
function r_null(): string { return null; }
function r_obj(): float { return new stdClass; }
function r_widen(): float { return 3; }
function r_tostr(): string { return 7; }
function r_bool(): bool { return 1; }
function r_mixed($v): int { return $v; }
function r_ok(): int { return 5; }

function show(string $what): void { echo $what, "\n"; }
try { var_dump(r_str()); } catch (TypeError $e) { show(get_class($e) . ": " . $e->getMessage() . " (line " . $e->getLine() . ")"); }
try { var_dump(r_num()); } catch (TypeError $e) { show($e->getMessage()); }
try { var_dump(r_arr()); } catch (TypeError $e) { show($e->getMessage()); }
try { var_dump(r_null()); } catch (TypeError $e) { show($e->getMessage()); }
try { var_dump(r_obj()); } catch (TypeError $e) { show($e->getMessage()); }
try { var_dump(r_widen()); } catch (TypeError $e) { show($e->getMessage()); }
try { var_dump(r_tostr()); } catch (TypeError $e) { show($e->getMessage()); }
try { var_dump(r_bool()); } catch (TypeError $e) { show($e->getMessage()); }
try { var_dump(r_ok()); } catch (TypeError $e) { show($e->getMessage()); }
foreach ([7, "8", "nine", 1.0, true, null] as $v) {
    try {
        var_dump(r_mixed($v));
    } catch (TypeError $e) {
        show($e->getMessage());
    }
}
