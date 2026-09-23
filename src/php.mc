// php.mc -- PHP 8.5 source, taught to mc as one Tier 3 module.
//
// The rule the whole compiler rests on is docs/plan.md D4: a variable's type
// is its first assignment's and never changes, so every expression has a
// STATIC php type and the lowering (D10) is a native value, never a zval,
// wherever the compiler knows enough to make it one.
//
// The shape, measured by probes/t4 before any of this existed:
//   * ONE word registration owns the grammar -- syntax("<?php", &ph_program).
//     Every PHP keyword stays an ordinary identifier matched by str_eq,
//     because a registration reserves its word for the whole program and PHP
//     has about seventy.
//   * The expression grammar is the module's own: PHP's precedence is not
//     mc's.
//   * The byte stream is the module's own too. mc 1.1.0's p_skip_to(q) lets a
//     handler own a REGION the core has no grammar for -- '...', # comments,
//     #[Attr], inline html and "..." -- and syntax_expr("$", &f) makes $name
//     lex as the `$` token plus the ordinary identifier `name`.
//
// The parts below are included in order, because mc is single pass. Splitting
// this file is a presentation change and nothing else: the token stream mc
// sees is what probes/t10/php.mc was, byte for byte, and tests/carve.sh
// asserts it.

#include "decls.mc"
#include "lex.mc"
#include "node.mc"
#include "vars.mc"
#include "consts.mc"
#include "tables.mc"
#include "types.mc"
#include "expr.mc"
#include "builtin.mc"
#include "stmt.mc"
#include "lvalue.mc"
#include "closure.mc"
#include "class.mc"
#include "decl.mc"
#include "ext.mc"
#include "program.mc"
