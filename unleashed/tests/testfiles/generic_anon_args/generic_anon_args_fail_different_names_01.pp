{ %FAIL }
program generic_anon_args_fail_different_names_01;
{$mode unleashed}

// two named tuples with different field names are distinct types, so the
// specializations on them are incompatible

var
  x: TArray<(a, b: integer)>;
  y: TArray<(c, d: integer)>;

begin
  y := [(1, 2)];
  x := y;
end.
