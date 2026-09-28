<?php
// tests/ext.sh step 18 (classes.php says what): loaded and interpreted, the
// same bytes.
if (!function_exists('pc\make')) { require __DIR__ . '/classes.php'; }
echo var_export(class_exists('pc\Box'), true), "\n";
$b = new pc\Box(3);
echo $b->n, " ", $b->label, " ", $b->add(2), " ", $b->peek(), " ", $b->describe(), "\n";
$m = pc\make(5);
echo get_class($m), " ", $m->n, " ", $m->label, " ", pc\bump($m), " ", $m->n, "\n";
echo pc\kind($b), " ", pc\kind(new stdClass), "\n";
$d = new pc\Box();
echo $d->describe(), "\n";
try { echo $b->secret; } catch (Error $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; }
try { $b->secret = 1; } catch (Error $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; }
try { $b->hidden(); } catch (Error $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; }
$r = new ReflectionClass('pc\Box'); echo var_export($r->isFinal(), true), "\n";
