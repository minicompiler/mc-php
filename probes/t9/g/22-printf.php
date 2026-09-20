<?php
printf("[%d][%5d][%-5d][%05d][%+d][%+d]\n", 42, 42, 42, 42, 42, -42);
printf("[%s][%10s][%-10s][%.3s]\n", "abc", "abc", "abc", "abcdef");
printf("[%x][%X][%o][%b][%c]\n", 255, 255, 8, 5, 65);
printf("[%f][%.2f][%10.3f][%e][%.2E]\n", 1.5, 3.14159, 2.5, 1234.5, 1234.5);
printf("[%'*8d][%2\$s %1\$s]\n", 7, "a", "b");
echo sprintf("%s-%s", "x", "y"), "\n";
echo vsprintf("%s/%d/%s\n", ["a", 5, "b"]);
vprintf("%05.1f|%s\n", [2.25, "z"]);
