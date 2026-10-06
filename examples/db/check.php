<?php
// The slice-1 driver. Run with db.so loaded it prints the lines in check.expect;
// tests/examples.sh grades that, and grades the SAME SQL run through php's own
// SQLite3 class (oracle.php) against it. It is not a differential against
// db.php required: interpreted, the #[Extern] bodies are empty.
declare(strict_types=1);

$N = 1000;

// in memory: DDL, a prepared bulk load, aggregates, a text read
$db = db_open(":memory:");
echo "open ", $db !== 0 ? "ok" : "FAILED", "\n";
echo "create ", db_exec($db, "CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT, v INTEGER)"), "\n";
echo "load ", db_load($db, "t", $N), "\n";
echo "count ", db_scalar($db, "SELECT COUNT(*) FROM t"), "\n";
echo "sum ", db_scalar($db, "SELECT SUM(v) FROM t"), "\n";
echo "max ", db_scalar($db, "SELECT MAX(v) FROM t WHERE id <= 500"), "\n";
echo "name ", db_text($db, "SELECT name FROM t WHERE id = 777"), "\n";
echo "none ", db_scalar($db, "SELECT id FROM t WHERE id = -1"), "\n";

// the error paths: a bad statement is sqlite's own code and message, a duplicate
// key rolls the whole load back
echo "bad ", db_exec($db, "SELEKT 1"), " ", db_error($db), "\n";
echo "dup ", db_load($db, "t", 3), "\n";
echo "count ", db_scalar($db, "SELECT COUNT(*) FROM t"), "\n";
echo "close ", db_close($db), "\n";

// on disk: the rows survive the connection
$f = sys_get_temp_dir() . "/mcphp-db-" . getmypid() . ".sqlite";
@unlink($f);
$db = db_open($f);
db_exec($db, "CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT, v INTEGER)");
echo "file load ", db_load($db, "t", $N), "\n";
db_close($db);
$db = db_open($f);
echo "file count ", db_scalar($db, "SELECT COUNT(*) FROM t"), "\n";
db_close($db);
@unlink($f);

// a path that cannot be opened
echo "nodir ", db_open("/no/such/dir/x.sqlite"), "\n";
