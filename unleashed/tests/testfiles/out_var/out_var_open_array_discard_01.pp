{ %OPT=-Sew }
program out_var_open_array_discard_01;
{$mode unleashed}

// `_` at an open array parameter passes an empty array, silently: the
// discard is deliberate, so no warning (-Sew would turn one into an error)

var seen: integer;

procedure grab(out q: array of string);
begin
  seen := length(q);
end;

procedure touch(var q: array of integer);
begin
  seen := length(q);
end;

begin
  seen := -1;
  grab(_);
  if seen <> 0 then halt(1);
  seen := -1;
  touch(_);
  if seen <> 0 then halt(2);
end.
