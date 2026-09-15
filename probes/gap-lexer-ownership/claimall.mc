// A module that claims EVERY source and adds every lexeme PHP needs. If a byte
// still does not reach a handler with this registered, no Tier 3 registration
// can reach it: this is the whole of what the surface offers.
i64 ca_claim(uptr name) { return 1; }

i64 ca_dollar() { p_next(); return 0; }

void user_init() {
    tok_add("<?php", 5);
    tok_add("?>",  2);
    tok_add("'",   1);
    tok_add("#",   1);
    tok_add("#[",  2);
    tok_add("$",   1);
    source_claim(&ca_claim);
    syntax_expr("$", &ca_dollar);          // never fires for $name -- measured
}
