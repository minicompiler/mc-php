// vars.mc -- docs/plan.md D4: one type per variable, its first assignment's.
// 
// The rule that shapes the whole compiler. A variable's php type is fixed by
// its first assignment and never changes, so every expression has a STATIC
// php type and the lowering is a native value wherever it can be. A second
// assignment of another type is a named compile error, not a coercion.

// ---- D4: one type per variable, its first assignment's ---------------------
#define PH_MAXVAR 512

uptr ph_vname[PH_MAXVAR];
i64  ph_vtype[PH_MAXVAR];
// 1 when the variable holds a zval POINTER that must be written through:
// a by-reference parameter, `global $x`, a function `static`, and the value
// of `foreach as &$v`. Reading one is reading the zval; writing one is a
// store into it, which is what makes the alias visible to the other name.
i64  ph_vref[PH_MAXVAR];
// 1 when the variable is a NULLABLE SCALAR parameter carried natively: its
// value is the typed local v_<name> (ph_vtype's scalar type) and its php
// null-ness is the u8 local vn_<name>. A plain read is the value; `=== null`
// reads the flag (src/expr.mc); passing it to a matching parameter passes
// the pair (src/builtin.mc). Only src/decl.mc's param loop sets it.
i64  ph_vopt[PH_MAXVAR];
i64  ph_nvar;

// the mc name of the null flag of a native nullable-scalar variable
uptr ph_vflag(uptr d) { return ph_mangle(d, "vn_"); }
// 1 when variable d is a native nullable-scalar (reads v_d, flag vn_d)
i64 ph_is_opt(uptr d) {
    i64 i = ph_var_find(d);
    if (i < 0) return 0;
    return ld64(ph_vopt + i * 8);
}

i64 ph_var_find(uptr d) {
    i64 i = 0;
    loop {
        if (i >= ph_nvar) break;
        if (str_eq(ld64(ph_vname + i * 8), d)) return i;
        i = i + 1;
    }
    return -1;
}

i64 ph_var_type(uptr d) { return ld64(ph_vtype + ph_var_find(d) * 8); }

i64 ph_is_ref(uptr d) {
    i64 i = ph_var_find(d);
    if (i < 0) return 0;
    return ld64(ph_vref + i * 8);
}

// A variable that is ever aliased (`&$x`, a `global`, a by-reference use or
// parameter) has to be a zval from its FIRST assignment: the typed local it
// would otherwise be has no address a second name can share. The names come
// from a byte scan of every source, in ph_on_source, before anything is
// parsed -- a false positive costs a zval and nothing else.
#define PH_MAXREF 256
uptr ph_refn[PH_MAXREF];
i64  ph_nref;
uptr ph_gsetn[PH_MAXREF];
i64  ph_ngset;

void ph_gset_add(uptr n) {
    i64 i = 0;
    loop {
        if (i >= ph_ngset) break;
        if (str_eq(ld64(ph_gsetn + i * 8), n)) return;
        i = i + 1;
    }
    if (ph_ngset >= PH_MAXREF) return;
    st64(ph_gsetn + ph_ngset * 8, n);
    ph_ngset = ph_ngset + 1;
}

// The first ph_ngtop names of ph_gsetn -- those the scan had when the top
// level began (ph_program) -- are bound to their global-table entry for the
// whole top level: php's top-level scope IS the global table. A name a
// later `require` adds is bound at its first top-level assignment instead.
i64 ph_ngtop;
i64 ph_gtop_has(uptr n) {
    i64 i = 0;
    loop {
        if (i >= ph_ngtop) break;
        if (str_eq(ld64(ph_gsetn + i * 8), n)) return 1;
        i = i + 1;
    }
    return 0;
}

// bind the names, ONCE, before the first top-level statement is compiled;
// ph_gtop_prologue writes the statements that bind them at run time
void ph_gtop_bind() {
    ph_ngtop = ph_ngset;
    i64 i = 0;
    loop {
        if (i >= ph_ngtop) break;
        uptr d = ld64(ph_gsetn + i * 8);
        ph_var_bind(d, PT_MIXED);
        ph_set_ref(d);
        i = i + 1;
    }
}
// An assignment that REBINDS a name -- foreach's variables, a reference
// assignment -- rather than storing into it. For a top-level name bound to
// the global table, the table is what changes: a value is stored into the
// entry, a reference makes the entry that zval (php_gbind). A block, so a
// caller may chain it like the one assignment it replaces.
i64 ph_rebind(uptr d, i64 v, i64 byref) {
    if (!ph_toplevel || !ph_gtop_has(d)) return ph_set(ph_mangle(d, "v_"), v);
    i64 lv = node_new(N_IDENT, ph_tline, ph_tfile);
    set_nd_name(lv, ph_mangle(d, "v_"));
    set_nd_type(lv, ty_pzv);
    i64 s = node_new(N_EXPRSTMT, ph_tline, ph_tfile);
    if (!byref) set_nd_a(s, ph_c2("php_zv_store", lv, v, ty_pzv));
    if (byref) {
        set_nd_a(s, ph_c2("php_gbind", ph_strlit(d + 1, cstrlen(d + 1)), lv, TY_VOID));
        i64 a = ph_set(ph_mangle(d, "v_"), v);
        set_nd_next(a, s);
        s = a;
    }
    i64 b = node_new(N_BLOCK, ph_tline, ph_tfile);
    set_nd_a(b, s);
    return b;
}

i64 ph_gtop_prologue() {
    i64 head = 0;
    i64 tail = 0;
    i64 i = 0;
    loop {
        if (i >= ph_ngtop) break;
        uptr d = ld64(ph_gsetn + i * 8);
        i64 s = ph_set(ph_mangle(d, "v_"), ph_c1("php_gtop", ph_strlit(d + 1, cstrlen(d + 1)), ty_pzv));
        if (tail) set_nd_next(tail, s);
        if (!tail) head = s;
        tail = s;
        i = i + 1;
    }
    return head;
}

i64 ph_gset_has(uptr n) {
    i64 i = 0;
    loop {
        if (i >= ph_ngset) break;
        if (str_eq(ld64(ph_gsetn + i * 8), n)) return 1;
        i = i + 1;
    }
    return 0;
}

void ph_refset_add(uptr n) {
    i64 i = 0;
    loop {
        if (i >= ph_nref) break;
        if (str_eq(ld64(ph_refn + i * 8), n)) return;
        i = i + 1;
    }
    if (ph_nref >= PH_MAXREF) return;
    st64(ph_refn + ph_nref * 8, n);
    ph_nref = ph_nref + 1;
}

i64 ph_refset_has(uptr n) {
    i64 i = 0;
    loop {
        if (i >= ph_nref) break;
        if (str_eq(ld64(ph_refn + i * 8), n)) return 1;
        i = i + 1;
    }
    return 0;
}

// A php `$s++` on a STRING changes the variable's type -- "5"++ is int(6) --
// which D4 forbids of a typed local. The same byte scan that finds `&$x`
// finds `$x++`, and a variable whose first assignment is a string and which
// is incremented somewhere is bound `mixed` instead: a zval can hold both
// answers and php_zv_inc already has php's rules. An int or float counter is
// untouched, which is what keeps every `for ($i = 0; ...; $i++)` a native i64.
uptr ph_incn[PH_MAXREF];
i64  ph_ninc;

void ph_incset_add(uptr n) {
    i64 i = 0;
    loop {
        if (i >= ph_ninc) break;
        if (str_eq(ld64(ph_incn + i * 8), n)) return;
        i = i + 1;
    }
    if (ph_ninc >= PH_MAXREF) return;
    st64(ph_incn + ph_ninc * 8, n);
    ph_ninc = ph_ninc + 1;
}

i64 ph_incset_has(uptr n) {
    i64 i = 0;
    loop {
        if (i >= ph_ninc) break;
        if (str_eq(ld64(ph_incn + i * 8), n)) return 1;
        i = i + 1;
    }
    return 0;
}

// The names of functions declared with a by-reference parameter, and (pass 2
// of the source scan) the variables a call to one passes: those have to be
// zvals from their first assignment, exactly as a name written `&$x` already
// is. Over-marking is what the rule above already costs -- a zval and nothing
// else -- so the scan does not track argument POSITIONS, it marks every
// $variable inside the call's parentheses.
#define PH_MAXBRF 192
uptr ph_brfn[PH_MAXBRF];
i64  ph_nbrf;

void ph_brf_add(uptr n) {
    i64 i = 0;
    loop {
        if (i >= ph_nbrf) break;
        if (str_eq(ld64(ph_brfn + i * 8), n)) return;
        i = i + 1;
    }
    if (ph_nbrf >= PH_MAXBRF) return;
    st64(ph_brfn + ph_nbrf * 8, n);
    ph_nbrf = ph_nbrf + 1;
}

// The BUILTINS that take a by-reference argument, seeded before the first
// source is scanned: a call to one of them makes the variable it is passed a
// zval, exactly as a call to a user `function f(&$x)` does. Every other
// by-reference builtin here takes an ARRAY or an object, whose handle is
// already a pointer.
void ph_brf_init() {
    ph_brf_add("settype");
    ph_brf_add("parse_str");
    ph_brf_add("array_splice");
    ph_brf_add("similar_text");
    ph_brf_add("str_replace");
    ph_brf_add("str_ireplace");
    ph_brf_add("preg_match");
    ph_brf_add("preg_match_all");
    ph_brf_add("sscanf");
}

i64 ph_brf_has(uptr n) {
    i64 i = 0;
    loop {
        if (i >= ph_nbrf) break;
        if (str_eq(ld64(ph_brfn + i * 8), n)) return 1;
        i = i + 1;
    }
    return 0;
}

void ph_set_ref(uptr d) {
    ph_narrow_clear(ph_mangle(d, "v_"));          // an alias/by-ref ends the narrowing
    i64 i = ph_var_find(d);
    if (i >= 0) st64(ph_vref + i * 8, 1);
}

// a php function body has its OWN scope: it sees no enclosing variable (a
// closure's captures are copied in explicitly). The table is flat, so the
// outer entries are saved and put back rather than just counted.
uptr ph_scope_save() {
    uptr b = xalloc(ph_nvar * 32 + 32);
    st64(b, ph_nvar);
    i64 i = 0;
    loop {
        if (i >= ph_nvar) break;
        st64(b + 8 + i * 32, ld64(ph_vname + i * 8));
        st64(b + 16 + i * 32, ld64(ph_vtype + i * 8));
        st64(b + 24 + i * 32, ld64(ph_vref + i * 8));
        st64(b + 32 + i * 32, ld64(ph_vopt + i * 8));
        i = i + 1;
    }
    ph_nvar = 0;
    return b;
}

void ph_scope_restore(uptr b) {
    i64 n = ld64(b);
    i64 i = 0;
    loop {
        if (i >= n) break;
        st64(ph_vname + i * 8, ld64(b + 8 + i * 32));
        st64(ph_vtype + i * 8, ld64(b + 16 + i * 32));
        st64(ph_vref + i * 8, ld64(b + 24 + i * 32));
        st64(ph_vopt + i * 8, ld64(b + 32 + i * 32));
        i = i + 1;
    }
    ph_nvar = n;
}

// 1 when this is the variable's FIRST assignment (the caller emits N_VAR, not
// N_ASSIGN). A second assignment of another type is D4's named compile error.
void ph_var_bind_raw(uptr d, i64 ty) {
    i64 i = ph_var_find(d);
    if (i >= 0) { st64(ph_vtype + i * 8, ty); return; }
    if (ph_nvar >= PH_MAXVAR) err_at(ph_tfile, ph_tline, "mc-php: too many php variables");
    st64(ph_vname + ph_nvar * 8, d);
    st64(ph_vtype + ph_nvar * 8, ty);
    st64(ph_vref + ph_nvar * 8, 0);
    st64(ph_vopt + ph_nvar * 8, 0);
    ph_nvar = ph_nvar + 1;
}

// mark variable d (already bound) as a native nullable-scalar
void ph_set_opt(uptr d) {
    i64 i = ph_var_find(d);
    if (i >= 0) st64(ph_vopt + i * 8, 1);
}

// if mcname is the value local (v_<name>) of a native nullable-scalar
// variable, return its null-flag local's name (vn_<name>), else 0. The
// lowered node of a read carries the mangled name, so `$x === null` finds
// the flag from it (src/expr.mc).
uptr ph_opt_flag_of(uptr mcname) {
    i64 i = 0;
    loop {
        if (i >= ph_nvar) break;
        if (ld64(ph_vopt + i * 8)) {
            uptr d = ld64(ph_vname + i * 8);
            if (str_eq(ph_mangle(d, "v_"), mcname)) return ph_mangle(d, "vn_");
        }
        i = i + 1;
    }
    return 0;
}

i64 ph_var_bind(uptr d, i64 ty) {
    if (ty == PT_STRING && ph_incset_has(d)) ty = PT_MIXED;
    i64 i = ph_var_find(d);
    if (i < 0) {
        if (ph_nvar >= PH_MAXVAR) err_at(ph_tfile, ph_tline, "mc-php: too many php variables");
        st64(ph_vname + ph_nvar * 8, d);
        st64(ph_vtype + ph_nvar * 8, ty);
        st64(ph_vref + ph_nvar * 8, 0);
        st64(ph_vopt + ph_nvar * 8, 0);
        ph_nvar = ph_nvar + 1;
        ph_local(ph_mangle(d, "v_"), ph_mcty(ty));
        // a packed element held in a variable: the value and php's null
        // (src/packed.mc), two locals
        return 1;
    }
    i64 was = ld64(ph_vtype + i * 8);
    if (was != ty) {
        uptr m = p_cat(d, " was ", 0, 5);
        m = p_cat(m, ph_tyname(was), 0, cstrlen(ph_tyname(was)));
        m = p_cat(m, ", assigned ", 0, 11);
        m = p_cat(m, ph_tyname(ty), 0, cstrlen(ph_tyname(ty)));
        ph_refuse2(ph_tfile, ph_tline, "a php variable has one type", m, "D4");
    }
    return 0;
}


// ---- declare(strict_types=1), per file ----------------------------------------
// php decides a call's argument checks by the CALLING file's mode and a
// return's by the declaring file's: each file that says strict_types=1 is
// listed here when its declare is parsed (its first statement), and a check
// lowered in it carries PC_STRICT (lib/php_rt.mc php_param_coerce).
#define PH_MAXSTRICT 256
uptr ph_strictf[PH_MAXSTRICT];
i64  ph_nstrict;
void ph_strict_add(uptr fl) {
    if (ph_nstrict >= PH_MAXSTRICT) err_at(fl, 1, "mc-php: too many files with declare(strict_types=1)");
    st64(ph_strictf + ph_nstrict * 8, fl);
    ph_nstrict = ph_nstrict + 1;
}
i64 ph_strict_bit(uptr fl) {
    i64 i = 0;
    loop {
        if (i >= ph_nstrict) break;
        if (str_eq(ld64(ph_strictf + i * 8), fl)) return 16;
        i = i + 1;
    }
    return 0;
}
