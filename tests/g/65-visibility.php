<?php
// a failed visibility check has to STOP the access, name the visibility, and
// cover a static property and a static method as well as an instance one
class C {
    private $p = 1;
    protected $q = 2;
    private static $s = 3;
    private static function sm() { return 4; }
    private function im() { return 5; }
    function ok() { return $this->p + self::$s + self::sm() + $this->im(); }
}
$o = new C();
echo $o->ok(), "\n";
try { echo $o->p, "\n"; } catch (Error $e) { echo $e->getMessage(), "\n"; }
try { echo $o->q, "\n"; } catch (Error $e) { echo $e->getMessage(), "\n"; }
try { echo C::$s, "\n"; } catch (Error $e) { echo $e->getMessage(), "\n"; }
try { echo C::sm(), "\n"; } catch (Error $e) { echo $e->getMessage(), "\n"; }
try { echo $o->im(), "\n"; } catch (Error $e) { echo $e->getMessage(), "\n"; }
var_dump(isset($o->p));
