{ %PRECOMPILE=utuple_generic_alias_unit_01.pas }
program tuple_generic_alias_unit_01;

{$mode unleashed}

// a generic tuple alias declared in another unit specializes from its PPU

uses utuple_generic_alias_unit_01;

type
  TIS = TPair<integer, string>;

var
  p: TIS;
  q: TPos<double, boolean>;

begin
  p := pairUp<integer, string>(3, 'three');
  if (p.left <> 3) or (p.right <> 'three') then halt(1);

  q := (1.5, true);
  if (firstOf<double, boolean>(q) <> 1.5) or not q._2 then halt(2);

  var (l, r) := p;
  if (l <> 3) or (r <> 'three') then halt(3);

  writeln(p);
end.
