program generic_anon_args_positional_named_01;
{$mode unleashed}

// a positional and a named tuple of the same shape name different
// specializations that stay assignment compatible, like the tuples themselves

var
  pos: TArray<(integer, integer)>;
  named: TArray<(a, b: integer)>;

begin
  pos := [(1, 2)];
  named := pos;
  if named[0].b <> 2 then halt(1);
  named := [(3, 4)];
  pos := named;
  if pos[0]._1 <> 3 then halt(2);
end.
