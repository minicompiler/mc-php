/* The .so side: a flat-namespace bundle, the shape a php extension has.
 * mc_answer is undefined here and resolved at dlopen against the host. */
long mc_answer(void);
long go(void) { return mc_answer(); }
