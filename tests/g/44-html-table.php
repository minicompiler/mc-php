<?php
$t = get_html_translation_table(HTML_ENTITIES);
var_dump(count($t), $t["é"], $t["€"]);
var_dump(get_html_translation_table(HTML_SPECIALCHARS, ENT_NOQUOTES));
