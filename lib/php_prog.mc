// php_prog.mc -- the program road's half of lib/php_rt.mc § who owns a
// string: its php_str_alloc and php_str_free, and stand-ins for the four Zend
// allocator entries.
//
// Pushed only when there is no [extension] table (src/program.mc); on the
// extension road lib/php_ext.mc defines the same four names over _emalloc,
// _efree, _erealloc and free(3). The runtime calls them directly rather than
// through a pointer, because they are the hottest calls it makes on that
// road, and a program never reaches them: every string it builds is the
// arena's (MCPHP_RC=check included -- that mode poisons, it frees nothing).
uptr phx_em(i64 n) { php_die("mc-php: a Zend allocation on the program road\n", 46); return 0; }
void phx_ef(uptr p) { php_die("mc-php: a Zend free on the program road\n", 40); }
uptr phx_er(uptr p, i64 n) { php_die("mc-php: a Zend reallocation on the program road\n", 48); return 0; }
void phx_pf(uptr p) { php_die("mc-php: a C-library free on the program road\n", 45); }

// every string a program builds is the arena's, and immutable -- unless
// MCPHP_RC=check, where it is counted (php_str_mk says which)
uptr php_str_alloc(i64 n) { return php_str_mk(n, 1); }

// A program frees nothing: a string reaches zero only in check mode, and is
// POISONED -- a length no string has -- and a string that is already dead
// dies loudly here, which is where a second release or a release of a stale
// pointer ends up.
void php_str_free(uptr s) {
    if (ld32(s + 4) == ZS_DEAD) php_rc_dead(s);
    st32(s, 0);
    st32(s + 4, ZS_DEAD);
    st64(s + 16, 1099511627776);
}

// the temporaries above mark m die (lib/php_rt.mc § who owns a string); a
// pool entry is never 0 and never interned, so the release is the count alone
void php_rc_drain(i64 m) {
    i64 i = ph_pn;
    uptr p = ph_pool;
    loop {
        if (i <= m) break;
        i = i - 1;
        uptr s = ld64(p + (i << 3));
        i64 rc = ld32(s);
        if (rc > 1) st32(s, rc - 1);
        if (rc <= 1) php_str_free(s);
    }
    if (ph_pn > m) ph_pn = m;
}
