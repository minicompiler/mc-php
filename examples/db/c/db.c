/* db.c -- the C TWIN of examples/db: the same eight db_* functions as an
 * ordinary hand-written C Zend extension, over the same libsqlite3. It is the
 * REFERENCE the compiled PHP (db.php) is measured against (README.md), graded
 * by the same check.php against the same check.expect.
 *
 * Like db.php, it declares the handful of sqlite3 symbols it uses itself and
 * links NOTHING for them: on the extension road the loader resolves them from
 * php's own process, so a php with sqlite3 loaded is all it needs -- no
 * sqlite3.h, no -lsqlite3, no sqlite3 development package.
 *
 *     cc -bundle -undefined dynamic_lookup -O2 -o db.so db.c $(php-config --includes)
 *     cc -shared -fPIC -O2 -o db.so db.c $(php-config --includes)      # Linux
 */
#include "php.h"

/* the C ABI db.php declares with #[Extern('sqlite3')]; sqlite3 and sqlite3_stmt
 * are opaque, so a void* here */
extern int         sqlite3_open(const char *, void **);
extern int         sqlite3_close(void *);
extern int         sqlite3_exec(void *, const char *, void *, void *, char **);
extern const char *sqlite3_errmsg(void *);
extern int         sqlite3_prepare_v2(void *, const char *, int, void **, const char **);
extern int         sqlite3_step(void *);
extern int         sqlite3_reset(void *);
extern int         sqlite3_finalize(void *);
extern int         sqlite3_bind_int(void *, int, int);
extern int         sqlite3_bind_text(void *, int, const char *, int, void *);
extern int         sqlite3_column_int(void *, int);
extern const unsigned char *sqlite3_column_text(void *, int);
extern int         sqlite3_column_count(void *);
extern const char *sqlite3_column_name(void *, int);

#define SQLITE_ROW       100
#define SQLITE_DONE      101
#define SQLITE_TRANSIENT ((void *) -1)

/* a handle, or 0 when it cannot be opened; the half-open handle is closed */
PHP_FUNCTION(db_open)
{
    zend_string *path;
    ZEND_PARSE_PARAMETERS_START(1, 1) Z_PARAM_STR(path) ZEND_PARSE_PARAMETERS_END();
    void *db = NULL;
    int rc = sqlite3_open(ZSTR_VAL(path), &db);
    if (rc != 0) {
        if (db) sqlite3_close(db);
        RETURN_LONG(0);
    }
    RETURN_LONG((zend_long) (intptr_t) db);
}

PHP_FUNCTION(db_close)
{
    zend_long db;
    ZEND_PARSE_PARAMETERS_START(1, 1) Z_PARAM_LONG(db) ZEND_PARSE_PARAMETERS_END();
    RETURN_LONG(sqlite3_close((void *) (intptr_t) db));
}

PHP_FUNCTION(db_exec)
{
    zend_long db;
    zend_string *sql;
    ZEND_PARSE_PARAMETERS_START(2, 2) Z_PARAM_LONG(db) Z_PARAM_STR(sql) ZEND_PARSE_PARAMETERS_END();
    RETURN_LONG(sqlite3_exec((void *) (intptr_t) db, ZSTR_VAL(sql), 0, 0, 0));
}

PHP_FUNCTION(db_error)
{
    zend_long db;
    ZEND_PARSE_PARAMETERS_START(1, 1) Z_PARAM_LONG(db) ZEND_PARSE_PARAMETERS_END();
    RETURN_STRING(sqlite3_errmsg((void *) (intptr_t) db));
}

/* insert rows 1..n as (id, 'row-<id>', id*7%1000) through one prepared
 * statement in one transaction; how many were stepped in, or -1 on the first
 * error, the whole load rolled back */
PHP_FUNCTION(db_load)
{
    zend_long db, n;
    zend_string *table;
    ZEND_PARSE_PARAMETERS_START(3, 3)
        Z_PARAM_LONG(db) Z_PARAM_STR(table) Z_PARAM_LONG(n)
    ZEND_PARSE_PARAMETERS_END();
    void *d = (void *) (intptr_t) db;
    if (sqlite3_exec(d, "BEGIN", 0, 0, 0) != 0) RETURN_LONG(-1);
    /* size to the table name so a long name is not truncated: db.php builds
       the same query as a PHP string, which has no fixed limit */
    char sql[ZSTR_LEN(table) + 64];
    snprintf(sql, sizeof sql, "INSERT INTO %s(id, name, v) VALUES (?, ?, ?)", ZSTR_VAL(table));
    void *st = NULL;
    if (sqlite3_prepare_v2(d, sql, -1, &st, 0) != 0) {
        sqlite3_exec(d, "ROLLBACK", 0, 0, 0);
        RETURN_LONG(-1);
    }
    zend_long done = 0;
    for (zend_long i = 1; i <= n; i++) {
        char name[32];
        int nn = snprintf(name, sizeof name, "row-" ZEND_LONG_FMT, i);
        if (sqlite3_bind_int(st, 1, (int) i) != 0
            || sqlite3_bind_text(st, 2, name, nn, SQLITE_TRANSIENT) != 0
            || sqlite3_bind_int(st, 3, (int) (i * 7 % 1000)) != 0
            || sqlite3_step(st) != SQLITE_DONE) {
            sqlite3_finalize(st);
            sqlite3_exec(d, "ROLLBACK", 0, 0, 0);
            RETURN_LONG(-1);
        }
        sqlite3_reset(st);
        done++;
    }
    sqlite3_finalize(st);
    if (sqlite3_exec(d, "COMMIT", 0, 0, 0) != 0) {
        sqlite3_exec(d, "ROLLBACK", 0, 0, 0);
        RETURN_LONG(-1);
    }
    RETURN_LONG(done);
}

/* first column of the first row as an int; -1 when there is no row or the
 * statement does not prepare */
PHP_FUNCTION(db_scalar)
{
    zend_long db;
    zend_string *sql;
    ZEND_PARSE_PARAMETERS_START(2, 2) Z_PARAM_LONG(db) Z_PARAM_STR(sql) ZEND_PARSE_PARAMETERS_END();
    void *st = NULL;
    if (sqlite3_prepare_v2((void *) (intptr_t) db, ZSTR_VAL(sql), -1, &st, 0) != 0) RETURN_LONG(-1);
    zend_long v = -1;
    if (sqlite3_step(st) == SQLITE_ROW) v = sqlite3_column_int(st, 0);
    sqlite3_finalize(st);
    RETURN_LONG(v);
}

/* the same, as text: "" when there is no row */
PHP_FUNCTION(db_text)
{
    zend_long db;
    zend_string *sql;
    ZEND_PARSE_PARAMETERS_START(2, 2) Z_PARAM_LONG(db) Z_PARAM_STR(sql) ZEND_PARSE_PARAMETERS_END();
    void *st = NULL;
    if (sqlite3_prepare_v2((void *) (intptr_t) db, ZSTR_VAL(sql), -1, &st, 0) != 0) RETURN_EMPTY_STRING();
    const char *s = "";
    if (sqlite3_step(st) == SQLITE_ROW) {
        const unsigned char *t = sqlite3_column_text(st, 0);
        if (t) s = (const char *) t;
    }
    RETVAL_STRING(s);
    sqlite3_finalize(st);
}

/* every row of a query as an associative array, column name => text value, in
 * column order; a php array of those arrays, empty when the statement does not
 * prepare or there are no rows */
PHP_FUNCTION(db_rows)
{
    zend_long db;
    zend_string *sql;
    ZEND_PARSE_PARAMETERS_START(2, 2) Z_PARAM_LONG(db) Z_PARAM_STR(sql) ZEND_PARSE_PARAMETERS_END();
    array_init(return_value);
    void *st = NULL;
    if (sqlite3_prepare_v2((void *) (intptr_t) db, ZSTR_VAL(sql), -1, &st, 0) != 0) return;
    int cols = sqlite3_column_count(st);
    while (sqlite3_step(st) == SQLITE_ROW) {
        zval row;
        array_init(&row);
        for (int i = 0; i < cols; i++) {
            const char *name = sqlite3_column_name(st, i);
            const unsigned char *val = sqlite3_column_text(st, i);
            add_assoc_string(&row, name ? name : "", val ? (char *) val : "");
        }
        add_next_index_zval(return_value, &row);
    }
    sqlite3_finalize(st);
}

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(ai_open, 0, 1, IS_LONG, 0)
    ZEND_ARG_TYPE_INFO(0, path, IS_STRING, 0)
ZEND_END_ARG_INFO()
ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(ai_close, 0, 1, IS_LONG, 0)
    ZEND_ARG_TYPE_INFO(0, db, IS_LONG, 0)
ZEND_END_ARG_INFO()
ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(ai_exec, 0, 2, IS_LONG, 0)
    ZEND_ARG_TYPE_INFO(0, db, IS_LONG, 0)
    ZEND_ARG_TYPE_INFO(0, sql, IS_STRING, 0)
ZEND_END_ARG_INFO()
ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(ai_error, 0, 1, IS_STRING, 0)
    ZEND_ARG_TYPE_INFO(0, db, IS_LONG, 0)
ZEND_END_ARG_INFO()
ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(ai_load, 0, 3, IS_LONG, 0)
    ZEND_ARG_TYPE_INFO(0, db, IS_LONG, 0)
    ZEND_ARG_TYPE_INFO(0, table, IS_STRING, 0)
    ZEND_ARG_TYPE_INFO(0, n, IS_LONG, 0)
ZEND_END_ARG_INFO()
ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(ai_scalar, 0, 2, IS_LONG, 0)
    ZEND_ARG_TYPE_INFO(0, db, IS_LONG, 0)
    ZEND_ARG_TYPE_INFO(0, sql, IS_STRING, 0)
ZEND_END_ARG_INFO()
ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(ai_text, 0, 2, IS_STRING, 0)
    ZEND_ARG_TYPE_INFO(0, db, IS_LONG, 0)
    ZEND_ARG_TYPE_INFO(0, sql, IS_STRING, 0)
ZEND_END_ARG_INFO()
ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(ai_rows, 0, 2, IS_ARRAY, 0)
    ZEND_ARG_TYPE_INFO(0, db, IS_LONG, 0)
    ZEND_ARG_TYPE_INFO(0, sql, IS_STRING, 0)
ZEND_END_ARG_INFO()

static const zend_function_entry db_functions[] = {
    PHP_FE(db_open, ai_open)
    PHP_FE(db_close, ai_close)
    PHP_FE(db_exec, ai_exec)
    PHP_FE(db_error, ai_error)
    PHP_FE(db_load, ai_load)
    PHP_FE(db_scalar, ai_scalar)
    PHP_FE(db_text, ai_text)
    PHP_FE(db_rows, ai_rows)
    PHP_FE_END
};

zend_module_entry db_module_entry = {
    STANDARD_MODULE_HEADER, "db", db_functions,
    NULL, NULL, NULL, NULL, NULL, "0.1.0", STANDARD_MODULE_PROPERTIES
};

ZEND_GET_MODULE(db)
