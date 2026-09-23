<?php
// exit(124) is a legitimate status and used to collide with the gate's own
// timeout sentinel: the alarm says whether it fired, the child's code does not.
echo "before\n";
exit(124);
