<?php
// The bench row: the example's own workload over db.so, over the C twin
// (c/db.c), and over php's own SQLite3 class interpreted. One process times ONE
// of the three -- the db_* functions resolve from whichever extension is
// loaded, so the module and the twin share this code; with no db extension
// loaded it falls to php's SQLite3 class. tests/examples.sh runs the three
// processes interleaved, three rounds, and divides the minimums.
//
//     php -d extension=build/db.so bench.php        # compiled
//     php -d extension=c-twin.so   bench.php c       # the C twin (c/)
//     php bench.php                                  # php's SQLite3, interpreted
//
// The module/C ratio is the example's DONE bar (README.md). The workload is the
// example's own story: a 1000-row bulk load through one prepared statement in a
// transaction, three aggregates, and a 200-row page pulled back whole with
// db_rows as an array of associative arrays (the slice-2 path) -- so it is
// dominated by libsqlite3, shared by all three, the way a real DB task is, and
// the compiled glue is the thin edge the ratio measures. (db_rows ON ITS OWN,
// over thousands of rows, is about 2.6x the C twin: a row assembled in php over
// the scalar column reads copies each column name and value into a php string
// where the twin writes the engine's array directly. README.md says so.)
declare(strict_types=1);

$mode = $argv[1] ?? 'compiled';
$useClass = !extension_loaded('db');
if ($useClass) { $mode = 'interpreted'; }

function work_db(): string {
    $db = db_open(':memory:');
    db_exec($db, 'CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT, v INTEGER)');
    db_load($db, 't', 1000);
    $c = db_scalar($db, 'SELECT COUNT(*) FROM t');
    $su = db_scalar($db, 'SELECT SUM(v) FROM t');
    $mx = db_scalar($db, 'SELECT MAX(v) FROM t WHERE id <= 500');
    $rows = db_rows($db, 'SELECT id, name, v FROM t WHERE id <= 200 ORDER BY id');
    $s = 0;
    foreach ($rows as $r) { $s += (int) $r['v'] + strlen($r['name']); }
    db_close($db);
    return "$c $su $mx " . count($rows) . " $s";
}

function work_class(): string {
    $d = new SQLite3(':memory:');
    $d->exec('CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT, v INTEGER)');
    $d->exec('BEGIN');
    $st = $d->prepare('INSERT INTO t(id, name, v) VALUES (?, ?, ?)');
    for ($i = 1; $i <= 1000; $i++) {
        $st->bindValue(1, $i); $st->bindValue(2, "row-$i"); $st->bindValue(3, $i * 7 % 1000);
        $st->execute(); $st->reset();
    }
    $d->exec('COMMIT');
    $c = (int) $d->querySingle('SELECT COUNT(*) FROM t');
    $su = (int) $d->querySingle('SELECT SUM(v) FROM t');
    $mx = (int) $d->querySingle('SELECT MAX(v) FROM t WHERE id <= 500');
    $res = $d->query('SELECT id, name, v FROM t WHERE id <= 200 ORDER BY id');
    $n = 0; $s = 0;
    while ($r = $res->fetchArray(SQLITE3_ASSOC)) { $n++; $s += (int) $r['v'] + strlen($r['name']); }
    $d->close();
    return "$c $su $mx $n $s";
}

$answer = $useClass ? work_class() : work_db();
$best = INF;
for ($i = 0; $i < 9; $i++) {
    $t = hrtime(true);
    $r = $useClass ? work_class() : work_db();
    $d = (hrtime(true) - $t) / 1e6;
    if ($r !== $answer) { echo "MISMATCH between runs\n"; exit(1); }
    if ($d < $best) { $best = $d; }
}
printf("%s %.3f %s\n", $mode, $best, $answer);
