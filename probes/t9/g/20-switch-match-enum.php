<?php
enum Suit: string { case Hearts = 'H'; case Spades = 'S';
  public function label(): string { return $this->name . "/" . $this->value; } }
foreach (Suit::cases() as $c) { echo $c->label(), " "; }
echo "\n", Suit::from('S')->name, " ", Suit::tryFrom('X') === null ? "none" : "?", "\n";
foreach ([1, 2, 3, "x"] as $v) {
  switch ($v) {
    case 1: echo "one ";
    case 2: echo "two "; break;
    case 3: echo "three "; break;
    default: echo "other ";
  }
  echo "| ", match(true) { $v === 1 => "a", $v === 2, $v === 3 => "bc", default => "d" }, "\n";
}
