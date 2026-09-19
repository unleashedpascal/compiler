unit utuple_generic_alias_unit_01;

{$mode unleashed}

// support unit for tuple_generic_alias_unit_01.pp: generic tuple aliases
// and generic routines over them exported through a PPU

interface

type
  TPair<A, B> = (left: A; right: B);
  TPos<A, B> = (A, B);

function pairUp<A, B>(const x: A; const y: B): TPair<A, B>;
function firstOf<A, B>(const p: TPos<A, B>): A;

implementation

function pairUp<A, B>(const x: A; const y: B): TPair<A, B>;
begin
  result := (x, y);
end;

function firstOf<A, B>(const p: TPos<A, B>): A;
begin
  result := p._1;
end;

end.
