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
