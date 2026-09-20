<?php
// The T9 workload: three shapes of ordinary PHP that are not a toy loop --
// a JSON round trip (ext/json, written in mc by this probe), a template
// renderer (string building and array lookup) and a sort-heavy pass
// (usort with a comparison closure). It runs under `php` unchanged and
// under an mc-php binary; probes/t9/bench/bench.sh times both.

function wl_make_records(int $n): array {
    $out = [];
    for ($i = 0; $i < $n; $i++) {
        $out[] = [
            "id"    => $i,
            "name"  => "item-" . $i,
            "score" => ($i * 7919) % 1000,
            "tags"  => ["a" . ($i % 5), "b" . ($i % 3)],
            "ok"    => ($i % 2) === 0,
            "ratio" => ($i % 97) / 8,
        ];
    }
    return $out;
}

function wl_json_roundtrip(array $rows, int $reps): int {
    $n = 0;
    for ($r = 0; $r < $reps; $r++) {
        $txt  = json_encode($rows);
        $back = json_decode($txt, true);
        $n   += count($back);
    }
    return $n;
}

// a template renderer: {{key}} substituted from a row, over every row
function wl_render(string $tpl, array $row): string {
    $out = "";
    $i   = 0;
    $n   = strlen($tpl);
    while ($i < $n) {
        $open = strpos($tpl, "{{", $i);
        if ($open === false) {
            $out .= substr($tpl, $i);
            break;
        }
        $out .= substr($tpl, $i, $open - $i);
        $close = strpos($tpl, "}}", $open);
        if ($close === false) {
            $out .= substr($tpl, $open);
            break;
        }
        $key = trim(substr($tpl, $open + 2, $close - $open - 2));
        if (isset($row[$key])) {
            $out .= (string) $row[$key];
        }
        $i = $close + 2;
    }
    return $out;
}

function wl_render_all(array $rows, int $reps): int {
    $tpl = "<li id=\"{{id}}\" class=\"{{name}}\">{{name}} scored {{score}} ({{ratio}})</li>\n";
    $n   = 0;
    for ($r = 0; $r < $reps; $r++) {
        foreach ($rows as $row) {
            $n += strlen(wl_render($tpl, $row));
        }
    }
    return $n;
}

function wl_sort(array $rows, int $reps): int {
    $n = 0;
    for ($r = 0; $r < $reps; $r++) {
        $copy = $rows;
        usort($copy, function ($a, $b) {
            if ($a["score"] === $b["score"]) {
                return strcmp($a["name"], $b["name"]);
            }
            return $a["score"] < $b["score"] ? -1 : 1;
        });
        $n += $copy[0]["score"] + $copy[count($copy) - 1]["score"];
    }
    return $n;
}
