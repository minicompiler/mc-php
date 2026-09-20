<?php
var_dump(bin2hex(pack("nvc*", 0x1234, 0x5678, 65, 66)));
var_dump(bin2hex(pack("N", 0x01020304)));
var_dump(bin2hex(pack("V", 0x01020304)));
var_dump(bin2hex(pack("A5", "ab")));
var_dump(bin2hex(pack("a5", "ab")));
var_dump(bin2hex(pack("Z5", "ab")));
var_dump(bin2hex(pack("H*", "1a2b3c")));
var_dump(bin2hex(pack("h*", "1a2b3c")));
var_dump(bin2hex(pack("J", 1)));
var_dump(bin2hex(pack("P", 1)));
var_dump(bin2hex(pack("d", 1.5)));
var_dump(bin2hex(pack("f", 1.5)));
var_dump(bin2hex(pack("x3")));
var_dump(unpack("Nval", pack("N", 123456)));
var_dump(unpack("C*", "abc"));
var_dump(unpack("A3str/Cx", "ab \x41"));
var_dump(unpack("d", pack("d", 2.25)));
var_dump(unpack("nfoo/nbar", pack("nn", 1, 2)));
