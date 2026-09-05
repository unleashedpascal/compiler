{ %EXPECTMSG="Out-variable bound to an open array parameter is empty, the callee cannot resize it; declare the parameter as TArray<T> or pass an existing array" }
program out_var_open_array_out_param_01;
{$mode unleashed}

// a bare `var y` at an `out` open array parameter becomes an empty dynamic
// array of the element type (with a warning), usable after the call

var seen: integer;

procedure grab(out q: array of string);
begin
  seen := length(q);
end;

begin
  grab(var y);
  if seen <> 0 then halt(1);
  if length(y) <> 0 then halt(2);
  y := ['a', 'b'];
  grab(y);
  if (seen <> 2) or (length(y) <> 2) then halt(3);
end.
