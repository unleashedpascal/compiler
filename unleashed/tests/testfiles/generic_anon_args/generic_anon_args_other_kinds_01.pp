program generic_anon_args_other_kinds_01;
{$mode unleashed}

// set, pointer, static array and record types as specialization arguments

var
  bits: TArray<set of 0..7>;
  ptrs: TArray<^integer>;
  fixed: TArray<array[0..1] of byte>;
  recs: TArray<record x, y: integer; end>;

procedure fillFixed(out f: TArray<array[0..1] of byte>);
begin
  f := [[1, 2], [3, 4]];
end;

begin
  bits := [[1, 3], [5]];
  if not (3 in bits[0]) or (3 in bits[1]) then halt(1);
  var k := 42;
  ptrs := [@k];
  if ptrs[0]^ <> 42 then halt(2);
  fillFixed(fixed);
  if fixed[1][0] <> 3 then halt(3);
  setlength(recs, 1);
  recs[0].x := 3; recs[0].y := 4;
  if recs[0].x + recs[0].y <> 7 then halt(4);
end.
