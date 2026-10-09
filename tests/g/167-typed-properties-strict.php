<?php
declare(strict_types=1);
// A typed property under strict_types: an int widens to a float, nothing else
// is coerced. Found while fixing PR #65's defects.
class P { public int $n = 0; public float $f = 0.0; } $p = new P; $p->f = 5; var_dump($p->f); try { $p->n = "5"; } catch (TypeError $e) { echo $e->getMessage(), "
"; }
class S { public static int $c = 0; } try { S::$c = "1"; } catch (TypeError $e) { echo $e->getMessage(), "
"; } var_dump(S::$c);
