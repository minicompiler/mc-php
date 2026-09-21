<?php
// D8: the SAME file runs under `php` with PHPUnit and under mc-php through
// probes/t10/bench/run.php, which is the "the compiler discovers test*
// methods" half done by hand for one class -- there is no `mc-php test`
// subcommand yet, and D6 forbids discovering them at run time.
//
//   php probes/t10/bench/run.php            (the shim, under php)
//   probes/t10/mcphp.sh probes/t10/bench/run.php
//   phpunit probes/t10/bench/WorkloadTest.php   (when phpunit is installed)

require __DIR__ . "/shim.php";
require __DIR__ . "/workload.php";

class WorkloadTest extends PHPUnit\Framework\TestCase
{
    public function testRecordsHaveEveryField(): void
    {
        $rows = wl_make_records(3);
        $this->assertSame(3, count($rows));
        $this->assertSame(0, $rows[0]["id"]);
        $this->assertSame("item-2", $rows[2]["name"]);
        $this->assertSame(true, $rows[0]["ok"]);
        $this->assertSame(false, $rows[1]["ok"]);
    }

    public function testJsonRoundTripPreservesEveryRow(): void
    {
        $rows = wl_make_records(5);
        $txt  = json_encode($rows);
        $back = json_decode($txt, true);
        $this->assertSame(5, count($back));
        $this->assertSame("item-3", $back[3]["name"]);
        $this->assertSame(true, $back[0]["ok"]);
        $this->assertSame(json_encode($rows), json_encode($back));
    }

    public function testJsonEncodesTheShapesPhpEncodes(): void
    {
        $this->assertSame("[1,2,3]", json_encode([1, 2, 3]));
        $this->assertSame('{"1":2}', json_encode([1 => 2]));
        $this->assertSame('"a\/b"', json_encode("a/b"));
        $this->assertSame('"\\u00e9"', json_encode("\u{00e9}"));
        $this->assertSame(false, json_encode("\x80"));
    }

    public function testRenderSubstitutesEveryKey(): void
    {
        $row = ["id" => 7, "name" => "x"];
        $this->assertSame("7:x", wl_render("{{id}}:{{name}}", $row));
        $this->assertSame("a b", wl_render("a b", $row));
        $this->assertSame(":", wl_render("{{missing}}:", $row));
        $this->assertSame("7", wl_render("{{ id }}", $row));
    }

    public function testSortIsTotalAndStableOnTheKey(): void
    {
        // wl_make_records gives 40 DISTINCT scores -- the step 7919 has
        // period 1000 modulo 1000 -- so the equal-score branch below never
        // ran and this test did not cover what its name promises. Three
        // records share a score, with names out of order, and the tie is
        // asserted by name.
        $rows = wl_make_records(40);
        $rows[] = ["id" => 100, "name" => "tie-c", "score" => 500,
                   "tags" => ["a0"], "ok" => true,  "ratio" => 1];
        $rows[] = ["id" => 101, "name" => "tie-a", "score" => 500,
                   "tags" => ["a1"], "ok" => false, "ratio" => 2];
        $rows[] = ["id" => 102, "name" => "tie-b", "score" => 500,
                   "tags" => ["a2"], "ok" => true,  "ratio" => 3];
        $copy = $rows;
        usort($copy, function ($a, $b) {
            if ($a["score"] === $b["score"]) {
                return strcmp($a["name"], $b["name"]);
            }
            return $a["score"] < $b["score"] ? -1 : 1;
        });
        $this->assertSame(43, count($copy));
        $prev = -1;
        $ties = [];
        foreach ($copy as $r) {
            $this->assertSame(true, $r["score"] >= $prev);
            $prev = (int) $r["score"];
            if ($r["score"] === 500 && $r["id"] >= 100) {
                $ties[] = $r["name"];
            }
        }
        // the equal-score branch really ran, and in name order
        $this->assertSame(3, count($ties));
        $this->assertSame("tie-a,tie-b,tie-c", implode(",", $ties));
    }

    public function testTheThreePhasesAgreeWithTheirCounts(): void
    {
        $rows = wl_make_records(6);
        $this->assertSame(12, wl_json_roundtrip($rows, 2));
        $this->assertSame(true, wl_render_all($rows, 2) > 0);
        $this->assertSame(true, wl_sort($rows, 2) > 0);
    }
}
