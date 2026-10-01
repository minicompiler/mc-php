<?php
// tests/ext.sh step 20b (threads.php says what): the thread API on the
// extension road, one request, graded against its recording.
echo "before any thread: ", th\mode(), "\n";
$want = 0;
for ($t = 0; $t < 4; $t++) $want += th\work(200, $t);
echo "4 threads through the API: ", th\api(4, 200) === $want ? "agree" : "MISMATCH", "\n";
echo "after the joins: ", th\mode(), "\n";
echo "a joined thread's values: ", th\keep(3), "\n";
echo "a detached thread's values: ", th\keep_detached(5), "\n";
echo "rethrown: ", th\rethrow(), "\n";
echo "a php callable: ", th\refuse(fn() => 1), "\n";
echo "destructors: ", th\dtors(), "\n";
echo "sync from 4 compiled threads: ", th\sy_count(4, 5000), "\n";
echo "the process's atomic, made at MINIT: ", th\sy_hit(), "\n";
$m = th\sy_mutex();
th\sy_lock($m);
try { th\sy_lock($m); } catch (Error $e) { echo "sync refused: ", $e->getMessage(), "\n"; }
th\sy_unlock($m);
try { th\sy_unlock($m); } catch (Error $e) { echo "sync refused: ", $e->getMessage(), "\n"; }
try { th\sy_load($m); } catch (Error $e) { echo "sync refused: ", $e->getMessage(), "\n"; }
echo "sync blocking, 8 compiled threads: ", th\sy_block(8), "\n";
// await (docs/threads.md § Step 5): a module function reached from the engine
// cannot suspend -- an EG frame is open, so await is refused BY NAME (it would
// corrupt the executor on resume). The guard is phx_depth != 0.
try { th\engine_await(); echo "engine await: no throw\n"; }
catch (\Throwable $e) { echo "engine await: ", $e->getMessage(), "\n"; }
// last, and echoing nothing after it: the thread's line is the output's last
th\detach_late(100);
