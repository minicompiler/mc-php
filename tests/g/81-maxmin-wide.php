<?php
// max/min take more than the ten values the runtime entry point carries:
// the call folds in chunks and the answer is php's.
echo max(1,2,3,4,5,6,7,8,9,10,11), "\n";
echo min(11,10,9,8,7,6,5,4,3,2,1), "\n";
echo max(...[1,2,3,4,5,6,7,8,9,10,99]), "\n";
echo min(...[5,4,3,2,1,0,-1,-2,-3,-4,-5]), "\n";
// and the shapes that were already right
echo max(5,3), " ", min(5,3), "\n";
echo max([4,9,2]), " ", min([4,9,2]), "\n";
echo max("10","9a"), "\n";
echo max(1.5, 2), " ", min(1.5, 2), "\n";
