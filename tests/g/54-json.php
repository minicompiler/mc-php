<?php
var_dump(json_encode(["a"=>1,"b"=>[1,2],"c"=>null,"d"=>true,"e"=>1.5,"f"=>"x\"y/z\n\u{00e9}"]));
var_dump(json_encode([1,2,3]), json_encode([1=>2]), json_encode(1.0), json_encode("\xc3\xa9"), json_encode("\x80"), json_last_error_msg());
var_dump(json_decode("[1,2]"), json_decode('{"a":1}'), json_decode('{"a":1}', true), json_decode("1.5"), json_decode("bad"), json_decode('"é"'), json_decode("null"));
var_dump(json_encode(json_decode('{"x":[1,{"y":"z"}],"n":null}', true)));
var_dump(json_decode('{"a":{"b":[1,2,{"c":true}]}}', true));
