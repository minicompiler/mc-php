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
i64  ph_nvar;

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
    i64 i = ph_var_find(d);
    if (i >= 0) st64(ph_vref + i * 8, 1);
}

// a php function body has its OWN scope: it sees no enclosing variable (a
// closure's captures are copied in explicitly). The table is flat, so the
// outer entries are saved and put back rather than just counted.
uptr ph_scope_save() {
    uptr b = xalloc(ph_nvar * 24 + 24);
    st64(b, ph_nvar);
    i64 i = 0;
    loop {
        if (i >= ph_nvar) break;
        st64(b + 8 + i * 24, ld64(ph_vname + i * 8));
        st64(b + 16 + i * 24, ld64(ph_vtype + i * 8));
        st64(b + 24 + i * 24, ld64(ph_vref + i * 8));
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
        st64(ph_vname + i * 8, ld64(b + 8 + i * 24));
        st64(ph_vtype + i * 8, ld64(b + 16 + i * 24));
        st64(ph_vref + i * 8, ld64(b + 24 + i * 24));
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
    ph_nvar = ph_nvar + 1;
}

i64 ph_var_bind(uptr d, i64 ty) {
    if (ty == PT_STRING && ph_incset_has(d)) ty = PT_MIXED;
    i64 i = ph_var_find(d);
    if (i < 0) {
        if (ph_nvar >= PH_MAXVAR) err_at(ph_tfile, ph_tline, "mc-php: too many php variables");
        st64(ph_vname + ph_nvar * 8, d);
        st64(ph_vtype + ph_nvar * 8, ty);
        st64(ph_vref + ph_nvar * 8, 0);
        ph_nvar = ph_nvar + 1;
        ph_local(ph_mangle(d, "v_"), ph_mcty(ty));
        // a packed element held in a variable: the value and php's null
        // (src/packed.mc), two locals
        if (ty == PT_INULL) ph_local(ph_mangle(d, "vn_"), TY_I64);
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

