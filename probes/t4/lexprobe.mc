#include <mc/host>
#include <mc/core>

void user_init() {
    tok_add("?->", 3);
    tok_add("??=", 3);
    tok_add("??",  2);
    tok_add("::",  2);
    tok_add("**",  2);
    tok_add("...", 3);
    tok_add("<=>", 3);
    tok_add(".=",  2);
    tok_add("->",  2);
    tok_add("<>",  2);
    tok_add("<?php", 5);
    tok_add("?>",  2);
    tok_add("\\",  1);
    tok_add("<<<", 3);
    tok_add("#", 1);
    tok_add("#[", 2);
    tok_add("'",   1);
}
