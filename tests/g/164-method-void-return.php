<?php
// A method declared void that returns a value: php refuses it while
// compiling, as it does a function (PR #65 defect 4)
echo "never printed\n";
class C {
  function m(): void {
    return 1;
  }
}
