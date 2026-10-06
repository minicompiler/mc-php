<?php
// db -- slice 1 of the database example: sqlite3's C API called from PHP source.
//
// libsqlite3 is declared with #[Extern('sqlite3')] and an empty body
// (docs/php-extension.md § A C function): every parameter and return here is an
// int, a pointer-sized int (Ptr) or a string, which is all #[Extern] carries
// today. On the extension road the symbols resolve from php's own process, so a
// php with sqlite3 loaded (`php -m`) is all the module needs -- no -lsqlite3 in
// the link. Rows do NOT come back as arrays yet; that is slice 2.
//
// sqlite3_open and sqlite3_prepare_v2 return their handle through an out
// parameter (`sqlite3 **`). php has no pointer-to-pointer, so the out parameter
// is a string the module made at run time, of exactly 8 bytes, which C writes
// into and unpack('P') reads back (docs/php-extension.md says why a literal
// must never be used for this).
//
// The `db_*` functions are the published API, all ints and strings. A leading
// underscore is module-private, so the sqlite3_* declarations are never
// published and a handle is a plain php int.

#[Extern('sqlite3')] function sqlite3_open(string $file, string $ppDb): int {}
#[Extern('sqlite3')] function sqlite3_close(Ptr $db): int {}
#[Extern('sqlite3')] function sqlite3_exec(Ptr $db, string $sql, Ptr $cb, Ptr $arg, Ptr $err): int {}
#[Extern('sqlite3')] function sqlite3_errmsg(Ptr $db): string {}
#[Extern('sqlite3')] function sqlite3_prepare_v2(Ptr $db, string $sql, int $n, string $ppStmt, Ptr $tail): int {}
#[Extern('sqlite3')] function sqlite3_step(Ptr $stmt): int {}
#[Extern('sqlite3')] function sqlite3_reset(Ptr $stmt): int {}
#[Extern('sqlite3')] function sqlite3_finalize(Ptr $stmt): int {}
#[Extern('sqlite3')] function sqlite3_bind_int(Ptr $stmt, int $i, int $v): int {}
#[Extern('sqlite3')] function sqlite3_bind_text(Ptr $stmt, int $i, string $v, int $n, Ptr $destructor): int {}
#[Extern('sqlite3')] function sqlite3_column_int(Ptr $stmt, int $i): int {}
#[Extern('sqlite3')] function sqlite3_column_text(Ptr $stmt, int $i): string {}

const _SQLITE_ROW = 100;
const _SQLITE_DONE = 101;
// SQLITE_TRANSIENT is (void(*)(void*))-1: sqlite copies the text before the call returns
const _SQLITE_TRANSIENT = -1;

// The 8 bytes `sqlite3 **` is written into, read back as the pointer.
function _out8(): string { return str_repeat("\0", 8); }
function _ptr(string $b): int { return unpack('P', $b)[1]; }

// A handle, or 0 when the database cannot be opened (":memory:" is private to
// this connection). The half-open handle sqlite hands back on failure is closed.
function db_open(string $path): int {
    $out = _out8();
    $rc = sqlite3_open($path, $out);
    $db = _ptr($out);
    if ($rc !== 0) {
        if ($db !== 0) sqlite3_close($db);
        return 0;
    }
    return $db;
}

function db_close(int $db): int { return sqlite3_close($db); }

// DDL/DML with no result rows: sqlite's own return code, 0 on success.
function db_exec(int $db, string $sql): int { return sqlite3_exec($db, $sql, 0, 0, 0); }

function db_error(int $db): string { return sqlite3_errmsg($db); }

// Insert rows 1..$n as (id, 'row-<id>', id * 7 % 1000) through ONE prepared
// statement inside one transaction -- the shape a bulk load has -- and answer
// how many rows were stepped in, or -1 on the first error.
function db_load(int $db, string $table, int $n): int {
    if (db_exec($db, "BEGIN") !== 0) return -1;
    $out = _out8();
    if (sqlite3_prepare_v2($db, "INSERT INTO $table(id, name, v) VALUES (?, ?, ?)", -1, $out, 0) !== 0) {
        db_exec($db, "ROLLBACK");
        return -1;
    }
    $st = _ptr($out);
    $done = 0;
    for ($i = 1; $i <= $n; $i++) {
        sqlite3_bind_int($st, 1, $i);
        sqlite3_bind_text($st, 2, "row-" . $i, -1, _SQLITE_TRANSIENT);
        sqlite3_bind_int($st, 3, $i * 7 % 1000);
        if (sqlite3_step($st) !== _SQLITE_DONE) {
            sqlite3_finalize($st);
            db_exec($db, "ROLLBACK");
            return -1;
        }
        sqlite3_reset($st);
        $done++;
    }
    sqlite3_finalize($st);
    if (db_exec($db, "COMMIT") !== 0) return -1;
    return $done;
}

// First column of the first row of a query, as an int; -1 when there is no row
// or the statement does not prepare.
function db_scalar(int $db, string $sql): int {
    $out = _out8();
    if (sqlite3_prepare_v2($db, $sql, -1, $out, 0) !== 0) return -1;
    $st = _ptr($out);
    $v = -1;
    if (sqlite3_step($st) === _SQLITE_ROW) $v = sqlite3_column_int($st, 0);
    sqlite3_finalize($st);
    return $v;
}

// The same, as text: the first column of the first row, "" when there is none.
function db_text(int $db, string $sql): string {
    $out = _out8();
    if (sqlite3_prepare_v2($db, $sql, -1, $out, 0) !== 0) return "";
    $st = _ptr($out);
    $s = "";
    if (sqlite3_step($st) === _SQLITE_ROW) $s = sqlite3_column_text($st, 0);
    sqlite3_finalize($st);
    return $s;
}
