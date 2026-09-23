<?php
// ANY callable the dev already has. Body stays interpreted; never compiled.
function pesado(string $n): array {           // named function
    $k = (int)$n; $s = 0;
    for ($i = 1; $i <= 4_000_000; $i++) { $s += ($i * $k) % 7; }
    return ['arg' => $n, 'soma' => $s, 'pid' => getmypid()];
}
class Servico { public function metodo(string $x): string { return strtoupper($x) . "!"; } }

$args = ['1','2','3','4','5','6','7','8'];

$t = hrtime(true);
$seq = array_map('pesado', $args);
$tseq = (hrtime(true)-$t)/1e6;

\awaitable\reset();
$t = hrtime(true);
$par = \awaitable\parallel('pesado', ...$args);
$tpar = (hrtime(true)-$t)/1e6;

printf("sequencial  %8.1f ms\n", $tseq);
printf("parallel    %8.1f ms   %.1fx   pids distintos: %d\n", $tpar, $tseq/$tpar,
   count(array_unique(array_column($par, 'pid'))));
printf("mesmos resultados: %s\n", var_export(
   array_column($seq,'soma') === array_column($par,'soma'), true));

// closure, arrow fn, metodo de objeto, funcao interna -- tudo callable
$svc = new Servico;
$r = \awaitable\parallel(fn(string $s) => "[$s]", 'a', 'b');
$m = \awaitable\parallel([$svc, 'metodo'], 'oi', 'tchau');
$i = \awaitable\parallel('strrev', 'abc', 'xyz');
var_dump($r, $m, $i);

// uma que lanca
$e = \awaitable\parallel(function(string $x) { throw new RuntimeException("estourou em $x"); }, 'q');
printf("erro: %s   errors()=%d\n", var_export($e[0], true), \awaitable\errors());

// e continua sendo await(...) devolvendo Intent
$w = \awaitable\await('awaitable\parallel', 'pesado', '1', '2');
printf("via await: failed=%s somas=%s\n", var_export($w->failed,true),
   implode(',', array_column($w->data, 'soma')));
