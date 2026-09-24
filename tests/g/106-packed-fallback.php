<?php
// The packed int array's proof FAILING (src/packed.mc): each function below
// builds an int array the way tests/g/105 does and then does ONE thing the
// proof does not allow, so the array stays php's own ordered hash of zvals
// (the end of tests/fixtures.sh checks that no $x here was lowered). The answers are
// php's either way; this is the list of what makes the proof fail.

function esc_implode(): string {          // passed to a library function
    $x = [];
    $x[] = 1; $x[] = 2;
    return implode(",", $x);
}

function show(array $a): int { return count($a) * 10 + $a[0]; }
function esc_user(): int {                // passed to a user function
    $x = [];
    $x[] = 3; $x[] = 4;
    return show($x);
}

function esc_return(): array {           // returned
    $x = [];
    $x[] = 5;
    return $x;
}

function esc_string_key(): int {         // a string key
    $x = [];
    $x[] = 1;
    $x["k"] = 2;
    return count($x) + $x["k"];
}

function esc_float(): string {           // a float stored
    $x = [];
    $x[] = 1;
    $x[] = 2.5;
    return var_export($x[1], true);
}

function esc_string_value(): string {    // a string stored
    $x = [];
    $x[] = "3";
    return gettype($x[0]);
}

function esc_null(): string {            // an element read stored as it is: null when absent
    $s = [];                             // (this one IS packed: only $x is under test)
    $s[] = 1;
    $x = [];
    $x[] = $s[5];
    return var_export($x[0], true);
}

function esc_copy(): int {               // copied into another variable
    $x = [];
    $x[] = 7;
    $y = $x;
    $y[] = 8;
    return count($x) * 10 + count($y);
}

function esc_foreach(): string {         // iterated
    $x = array_fill(0, 3, 2);
    $s = "";
    foreach ($x as $k => $v) { $s .= "$k:$v;"; }
    return $s;
}

function esc_isset(): string {           // isset / unset / ??
    $x = [];
    $x[] = 1; $x[] = 2;
    unset($x[0]);
    return var_export(isset($x[0]), true) . ($x[5] ?? "d") . count($x);
}

function esc_compound(): int {           // a compound assignment to an element
    $x = [];
    $x[] = 1;
    $x[0] += 5;
    $x[0]++;
    return $x[0];
}

function esc_capture(): int {            // captured by a closure
    $x = [];
    $x[] = 9;
    $f = function () use ($x) { return $x[0]; };
    return $f();
}

function esc_interp(): string {          // interpolated in a string
    $x = [];
    $x[] = 4;
    return "v=$x[0]";
}

function esc_cond_init(bool $c): int {   // initialised on one path only (called with
                                         // true: false is a crash on main too, docs/plan.md § 7)
    if ($c) { $x = []; }
    $x[] = 1;
    return count($x);
}

function esc_param(array $x): int {      // a parameter is the caller's array
    $x[] = 1;
    return count($x);
}

echo esc_implode(), "\n", esc_user(), "\n";
var_dump(esc_return());
echo esc_string_key(), " ", esc_float(), " ", esc_string_value(), " ", esc_null(), "\n";
echo esc_copy(), " ", esc_foreach(), " ", esc_isset(), " ", esc_compound(), " ", esc_capture(), "\n";
echo esc_interp(), " ", esc_cond_init(true), " ", esc_param([1, 2]), "\n";
