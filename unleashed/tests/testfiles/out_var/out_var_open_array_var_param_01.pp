{ %EXPECTMSG="Out-variable bound to an open array parameter is empty" }
program out_var_open_array_var_param_01;
{$mode unleashed}

// the same at a `var` open array parameter: the fresh dynamic array is nil,
// so the callee sees an empty array and the variable stays usable

var seen: integer;

procedure touch(var q: array of integer);
begin
  seen := length(q);
  for var i := 0 to high(q) do q[i] := q[i] * 2;
end;

begin
  touch(var z);
  if seen <> 0 then halt(1);
  if length(z) <> 0 then halt(2);
  z := [1, 2, 3];
  touch(z);
  if (seen <> 3) or (z[2] <> 6) then halt(3);
end.
