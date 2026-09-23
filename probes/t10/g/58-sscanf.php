<?php
var_dump(sscanf("age: 25 weight: 60kg", "age: %d weight: %dkg"));
var_dump(sscanf("hello world", "%s %s"));
var_dump(sscanf("1.5 abc", "%f %s"));
var_dump(sscanf("ab12", "%2s%d"));
var_dump(sscanf("x", "%d"));
var_dump(sscanf("ff", "%x"));
var_dump(sscanf("abc", "%c%c"));
var_dump(sscanf("100% done", "%d%% %s"));
var_dump(sscanf("nope", "yes"));
var_dump(sscanf("abc123", "%[a-z]%d"));
var_dump(setlocale(LC_ALL,"C"), setlocale(LC_ALL,"nonexistent_xx"), setlocale(LC_ALL,0), setlocale(LC_ALL,["zz_ZZ","C"]));
