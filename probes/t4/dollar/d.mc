i64 dl_var() {
    out_str(2, "  syntax_expr($) fired, id=");
    out_num(2, p_id());
    out_str(2, " name=");
    out_str(2, p_name());
    out_str(2, "\n");
    p_next();
    i64 n = node_new(N_INT, p_line(), p_file());
    set_nd_val(n, 7);
    return n;
}
void user_init() { syntax_expr("$", &dl_var); }
