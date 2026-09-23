<?php
// D8's mc-php half: the SAME WorkloadTest.php, driven by a runner that
// NAMES its test methods. D6 forbids discovering them at run time, so the
// list is written here -- which is what "the compiler discovers test*
// methods at COMPILE time" means until `mc-php test` exists.
//
//   php tests/bench/run.php
//   tests/mcphp.sh tests/bench/run.php
require __DIR__ . "/WorkloadTest.php";

$ok  = 0;
$bad = 0;

function shim_run(string $name, WorkloadTest $t): string
{
    // D6 keeps a method name that is a run-time string out, so the call is
    // a choice over the literal names the file declares
    if ($name === "testRecordsHaveEveryField") { $t->testRecordsHaveEveryField(); return ""; }
    if ($name === "testJsonRoundTripPreservesEveryRow") { $t->testJsonRoundTripPreservesEveryRow(); return ""; }
    if ($name === "testJsonEncodesTheShapesPhpEncodes") { $t->testJsonEncodesTheShapesPhpEncodes(); return ""; }
    if ($name === "testRenderSubstitutesEveryKey") { $t->testRenderSubstitutesEveryKey(); return ""; }
    if ($name === "testSortIsTotalAndStableOnTheKey") { $t->testSortIsTotalAndStableOnTheKey(); return ""; }
    if ($name === "testTheThreePhasesAgreeWithTheirCounts") { $t->testTheThreePhasesAgreeWithTheirCounts(); return ""; }
    return "no such test";
}

$names = [
    "testRecordsHaveEveryField",
    "testJsonRoundTripPreservesEveryRow",
    "testJsonEncodesTheShapesPhpEncodes",
    "testRenderSubstitutesEveryKey",
    "testSortIsTotalAndStableOnTheKey",
    "testTheThreePhasesAgreeWithTheirCounts",
];

foreach ($names as $n) {
    $t = new WorkloadTest();
    $err = "";
    try {
        $err = shim_run($n, $t);
    } catch (Exception $e) {
        // D4: $err is a string, so the zval getMessage answers is cast
        $err = (string) $e->getMessage();
    }
    if ($err === "") {
        echo "ok   ", $n, "\n";
        $ok = $ok + 1;
    } else {
        echo "FAIL ", $n, ": ", $err, "\n";
        $bad = $bad + 1;
    }
}
echo "tests: ", $ok, " ok / ", $bad, " failed\n";
