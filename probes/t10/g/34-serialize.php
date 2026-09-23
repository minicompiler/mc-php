<?php
var_dump(serialize([1, "a" => "b", 2.5, true, null]));
var_dump(unserialize('a:2:{i:0;i:1;s:1:"k";s:2:"vv";}'));
var_dump(serialize("hi"), serialize(42), serialize(null), serialize(false));
var_dump(unserialize(serialize([1,[2,3]])));
var_dump(str_getcsv('a,"b,c",d'));
var_dump(quoted_printable_encode("a=b\xc3\xa9"));
var_dump(quoted_printable_decode("a=3Db"));
var_dump(convert_uuencode("test"));
var_dump(convert_uudecode(convert_uuencode("test")));
var_dump(mb_internal_encoding());
