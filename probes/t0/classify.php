<?php
// probes/t0/classify.php -- the exact classifier breakdown.py drives.
//
// Reads one absolute .phpt (well, any .php-lexable) path per line from
// stdin; for each, tokenizes its --FILE-- section (already extracted by
// breakdown.py, one temp .php per source) with token_get_all() -- the real
// tokenizer, not a regex -- and prints one '|'-joined line:
//
//   path|d1|d5|autoload|d6|d4|status
//
// d1/d5/autoload/d6/d4 are 0 or 1; status is "ok" or "tokenize_error" (the
// source itself could not be tokenized -- rare, usually a --FILE-- that is
// deliberately malformed to test a parse error).
//
// D1 (docs/plan.md): eval(), create_function(), or assert() called with a
//     string literal argument.
// D5: include/require/_once whose target is not a plain string literal
//     (autoload is reported separately: an spl_autoload_register() call).
// D6: $$name, $obj->$dynamic, $obj->$dynamic(), new $c, $c::... -- anything
//     needing a name resolved at run time -- plus Reflection*, and the
//     seven introspection functions named in docs/plan.md D6.
// D4-suspect: a variable assigned two DIFFERENT literal kinds (number,
//     string, bool/null, array) within the same lexical function scope
//     (closures and methods each open one; class-property default values
//     are excluded by looking back for a visibility/var/readonly modifier).
//     This is a heuristic upper bound, not an AST-level type checker --
//     documented as such in docs/plan.md and probes/t0/RESULTS.md.

declare(strict_types=1);

function classify_source(string $src): array {
    $flags = ['d1' => 0, 'd5' => 0, 'autoload' => 0, 'd6' => 0, 'd4' => 0];
    try {
        $tokens = @token_get_all($src);
    } catch (\Throwable $e) {
        return [$flags, false];
    }
    if (!is_array($tokens)) {
        return [$flags, false];
    }

    $sig = [];
    foreach ($tokens as $t) {
        if (is_array($t)) {
            $id = $t[0];
            if ($id === T_WHITESPACE || $id === T_COMMENT || $id === T_DOC_COMMENT) {
                continue;
            }
            $sig[] = [$id, $t[1]];
        } else {
            $sig[] = [0, $t]; // plain punctuation: no dedicated token id
        }
    }
    $n = count($sig);

    $scope_stack = [];       // each: ['vars' => [name => [kind => true]], 'depth' => int]
    $global_vars = [];
    $depth = 0;
    $awaiting_brace = false;

    $finalize = function (array $vars) use (&$flags): void {
        foreach ($vars as $kinds) {
            if (count($kinds) >= 2) {
                $flags['d4'] = 1;
                return;
            }
        }
    };

    static $introspect = [
        'get_class_methods', 'get_object_vars', 'get_class_vars',
        'func_get_args', 'debug_backtrace', 'property_exists', 'method_exists',
    ];
    static $prop_modifiers = null;
    if ($prop_modifiers === null) {
        $prop_modifiers = [T_PUBLIC, T_PROTECTED, T_PRIVATE, T_VAR];
        if (defined('T_READONLY')) {
            $prop_modifiers[] = T_READONLY;
        }
    }

    for ($i = 0; $i < $n; $i++) {
        [$id, $text] = $sig[$i];

        if ($id === T_FUNCTION) {
            $awaiting_brace = true;
        } elseif ($awaiting_brace && $id === 0 && $text === ';') {
            $awaiting_brace = false; // an abstract/interface signature: no body
        }

        if ($id === 0 && $text === '{') {
            $depth++;
            if ($awaiting_brace) {
                $scope_stack[] = ['vars' => [], 'depth' => $depth];
                $awaiting_brace = false;
            }
        } elseif ($id === 0 && $text === '}') {
            if ($scope_stack && end($scope_stack)['depth'] === $depth) {
                $s = array_pop($scope_stack);
                $finalize($s['vars']);
            }
            $depth = max(0, $depth - 1);
        }

        // D1 -- eval / create_function / assert(string)
        if ($id === T_EVAL) {
            $flags['d1'] = 1;
        }
        if ($id === T_STRING) {
            $lname = strtolower($text);
            $calls_next = ($i + 1 < $n && $sig[$i + 1] === [0, '(']);
            if ($calls_next && $lname === 'create_function') {
                $flags['d1'] = 1;
            }
            if ($calls_next && $lname === 'assert') {
                $j = $i + 2;
                if ($j < $n && $sig[$j][0] === T_CONSTANT_ENCAPSED_STRING) {
                    $flags['d1'] = 1;
                }
            }
            if ($calls_next && $lname === 'spl_autoload_register') {
                $flags['autoload'] = 1;
            }
            if (in_array($lname, $introspect, true)) {
                $flags['d6'] = 1;
            }
            if (str_starts_with($lname, 'reflection')) {
                $flags['d6'] = 1;
            }
        }

        // D5 -- include/require of anything but a plain string literal
        if (in_array($id, [T_INCLUDE, T_INCLUDE_ONCE, T_REQUIRE, T_REQUIRE_ONCE], true)) {
            $j = $i + 1;
            if ($j < $n && $sig[$j] === [0, '(']) {
                $j++;
            }
            if ($j < $n && $sig[$j][0] === T_CONSTANT_ENCAPSED_STRING) {
                $k = $j + 1;
                if ($k < $n && $sig[$k][0] === 0 && !in_array($sig[$k][1], [';', ')', ','], true)) {
                    $flags['d5'] = 1; // a literal concatenated with something else
                }
            } elseif ($j < $n) {
                $flags['d5'] = 1; // a variable, a call, any other expression
            }
        }

        // D6 -- $$name, ->$dynamic, new $c, $c::
        if ($id === 0 && $text === '$' && $i + 1 < $n && $sig[$i + 1][0] === T_VARIABLE) {
            $flags['d6'] = 1;
        }
        if ($id === T_OBJECT_OPERATOR && $i + 1 < $n
            && ($sig[$i + 1][0] === T_VARIABLE || $sig[$i + 1] === [0, '$'])) {
            $flags['d6'] = 1;
        }
        if ($id === T_NEW && $i + 1 < $n && $sig[$i + 1][0] === T_VARIABLE) {
            $flags['d6'] = 1;
        }
        if ($id === T_VARIABLE && $i + 1 < $n && $sig[$i + 1][0] === T_DOUBLE_COLON) {
            $flags['d6'] = 1;
        }

        // D4-suspect -- $var = <literal>; with a kind that disagrees with an
        // earlier one for the same name in the same function scope. Skip a
        // T_VARIABLE that is itself the NAME half of $$name (the previous
        // token is a bare '$'): that assigns the variable $$name points at,
        // not $name.
        if ($id === T_VARIABLE && $i + 1 < $n && $sig[$i + 1] === [0, '=']
            && !($i > 0 && $sig[$i - 1] === [0, '$'])) {
            $is_prop_decl = false;
            for ($b = $i - 1; $b >= 0 && $b >= $i - 6; $b--) {
                $pid = $sig[$b][0];
                if ($pid === 0 && in_array($sig[$b][1], [';', '{', '}'], true)) {
                    break;
                }
                if (in_array($pid, $prop_modifiers, true)) {
                    $is_prop_decl = true;
                    break;
                }
            }
            if (!$is_prop_decl) {
                $kind = null;
                $v = $i + 2;
                if ($v < $n) {
                    [$vid, $vtext] = $sig[$v];
                    if ($vid === T_LNUMBER || $vid === T_DNUMBER) {
                        $kind = 'number';
                    } elseif ($vid === T_CONSTANT_ENCAPSED_STRING) {
                        $kind = 'string';
                    } elseif ($vid === T_STRING && in_array(strtolower($vtext), ['true', 'false', 'null'], true)) {
                        $kind = 'bool';
                    } elseif (($vid === 0 && $vtext === '[') || $vid === T_ARRAY) {
                        $kind = 'array';
                    }
                }
                if ($kind !== null) {
                    if ($scope_stack) {
                        $top = count($scope_stack) - 1;
                        $scope_stack[$top]['vars'][$text][$kind] = true;
                    } else {
                        $global_vars[$text][$kind] = true;
                    }
                }
            }
        }
    }

    while ($scope_stack) {
        $s = array_pop($scope_stack);
        $finalize($s['vars']);
    }
    $finalize($global_vars);

    return [$flags, true];
}

// Extract the --FILE-- section of a .phpt (the same frame php-src's own
// run-tests.php parses; --FILEEOF-- is folded into --FILE-- the same way).
// This is the .phpt FRAME, a fixed textual format -- not PHP source -- so a
// regex over the section markers is the right tool; the PHP inside is read
// only by the real tokenizer, above.
function extract_file_section(string $raw): ?string {
    $lines = preg_split('/(?<=\n)/', $raw);
    if (!$lines || strncmp($lines[0], '--TEST--', 8) !== 0) {
        return null;
    }
    $section = null;
    $body = '';
    foreach (array_slice($lines, 1) as $line) {
        if (preg_match('/^--([_A-Z]+)--/', $line, $m)) {
            if ($section === 'FILE') {
                return $body; // a later section closes --FILE--
            }
            $section = $m[1];
            $body = '';
            continue;
        }
        if ($section === 'FILE' || $section === 'FILEEOF') {
            $body .= $line;
        }
    }
    if ($section === 'FILE' || $section === 'FILEEOF') {
        return $section === 'FILEEOF' ? preg_replace('/[\r\n]+$/', '', $body) : $body;
    }
    return null; // no --FILE-- at all (FILE_EXTERNAL, PHPDBG-only, REDIRECTTEST...)
}

$out = fopen('php://stdout', 'w');
while (($path = fgets(STDIN)) !== false) {
    $path = rtrim($path, "\r\n");
    if ($path === '') {
        continue;
    }
    $raw = @file_get_contents($path);
    if ($raw === false) {
        fwrite($out, "$path|0|0|0|0|0|readerr\n");
        continue;
    }
    $src = extract_file_section($raw);
    if ($src === null) {
        fwrite($out, "$path|0|0|0|0|0|nofile\n");
        continue;
    }
    [$flags, $ok] = classify_source($src);
    fwrite($out, sprintf(
        "%s|%d|%d|%d|%d|%d|%s\n",
        $path, $flags['d1'], $flags['d5'], $flags['autoload'], $flags['d6'], $flags['d4'],
        $ok ? 'ok' : 'tokenize_error'
    ));
}
