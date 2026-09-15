// lexprobe.mc -- T4 table 1: what the core lexer makes of PHP, and how much of
// it a module can fix with tok_add alone. The compiler this builds teaches NO
// grammar; user_init does nothing but add lexemes. Whatever still dies here is
// a byte the core lexer keeps for itself.
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
    tok_add("'",   1);   // does not beat the char-literal rule -- measured
}
