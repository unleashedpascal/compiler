program array_literal_int_then_float_01;

{$mode unleashed}

// an integer element ahead of a float element must not pin the literal to
// LongInt; the literal still converts as a whole to an array of double

procedure check(const values: array of double; want: double);
begin
  if values[high(values)] <> want then halt(1);
end;

begin
  check([7.25, 2], 2);
  check([2, 7.25], 7.25);
  check([1, 2, 0.5], 0.5);
  var d: array of double := [8, 1.75];
  if (length(d) <> 2) or (d[0] <> 8) or (d[1] <> 1.75) then halt(2);
end.
