program generic_anon_args_cross_unit_01;
{$mode unleashed}

// a specialization on an anonymous type declared in one unit and the same
// shape written in another module are compatible without a shared alias,
// at const, out and var parameters alike

uses generic_anon_args_unit_01;

var
  pairs: TArray<(a: integer; b: string)>;
  rows: TArray<array of string>;

begin
  fillPairs(pairs);
  if sumPairs(pairs) <> 18 then halt(1);
  rows := [['x']];
  appendRow(rows);
  if (length(rows) <> 2) or (rows[1][1] <> 'z') then halt(2);
  fillPairs(var fresh);
  if fresh[1].b <> 'six' then halt(3);
end.
