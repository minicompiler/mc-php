<?php
// The same statements as check.php, run through php's own SQLite3 class: the
// independent oracle tests/examples.sh holds db.so's output against. It shares
// no code with db.php, only the SQL and the shape of the lines.
$N = 1000;

function load(SQLite3 $d, int $n): int {
    $d->exec("BEGIN");
    $s = $d->prepare("INSERT INTO t(id, name, v) VALUES (?, ?, ?)");
    for ($i = 1; $i <= $n; $i++) {
        $s->bindValue(1, $i); $s->bindValue(2, "row-$i"); $s->bindValue(3, $i * 7 % 1000);
        if (@$s->execute() === false) { $d->exec("ROLLBACK"); return -1; }
    }
    $d->exec("COMMIT");
    return $n;
}
function scalar(SQLite3 $d, string $q): int { $v = $d->querySingle($q); return $v === null ? -1 : (int)$v; }

$d = new SQLite3(":memory:");
echo "open ok\n";
echo "create ", $d->exec("CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT, v INTEGER)") ? 0 : 1, "\n";
echo "load ", load($d, $N), "\n";
echo "count ", scalar($d, "SELECT COUNT(*) FROM t"), "\n";
echo "sum ", scalar($d, "SELECT SUM(v) FROM t"), "\n";
echo "max ", scalar($d, "SELECT MAX(v) FROM t WHERE id <= 500"), "\n";
echo "name ", $d->querySingle("SELECT name FROM t WHERE id = 777"), "\n";
echo "none ", scalar($d, "SELECT id FROM t WHERE id = -1"), "\n";
$bad = @$d->exec("SELEKT 1") === false ? 1 : 0;
echo "bad ", $bad, " ", $d->lastErrorMsg(), "\n";
echo "dup ", load($d, 3), "\n";
echo "count ", scalar($d, "SELECT COUNT(*) FROM t"), "\n";
echo "close ", $d->close() ? 0 : 1, "\n";

$f = sys_get_temp_dir() . "/mcphp-dbo-" . getmypid() . ".sqlite";
@unlink($f);
$d = new SQLite3($f);
$d->exec("CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT, v INTEGER)");
echo "file load ", load($d, $N), "\n";
$d->close();
$d = new SQLite3($f);
echo "file count ", scalar($d, "SELECT COUNT(*) FROM t"), "\n";
$d->close();
@unlink($f);
// an unopenable path: SQLite3 throws, db_open's contract for the same case is 0
try { new SQLite3("/no/such/dir/x.sqlite"); $nodir = 1; } catch (Throwable $e) { $nodir = 0; }
echo "nodir ", $nodir, "\n";
