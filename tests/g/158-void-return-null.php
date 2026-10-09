<?php
// php names `return null;` in a `: void` function apart from any other value.
function quiet(): void { return NULL; }
quiet();
