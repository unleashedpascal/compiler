program generic_anon_args_tuple_param_01;
{$mode unleashed}

// a tuple or an `array of` type written directly as a specialization
// argument; the same shape names the same specialization wherever it appears

function make(out q: TArray<(a: integer; b: string)>): boolean;
begin
  setlength(q, 2);
  q[0] := (1, 'one');
  q[1].a := 2; q[1].b := 'two';
  result := true;
end;

function total(const items: TArray<(a: integer; b: string)>): integer;
begin
  result := 0;
  for var (n, s) in items do result += n + length(s);
end;

function nested(out q: TArray<array of string>): boolean;
begin
  q := [['p', 'q'], ['r']];
  result := true;
end;

var stored: TArray<(a: integer; b: string)>;

begin
  if not make(var t) then halt(1);
  if total(t) <> 9 then halt(2);
  stored := t;
  if length(stored) <> 2 then halt(3);
  if not nested(var n) then halt(4);
  if n[0][1] + n[1][0] <> 'qr' then halt(5);
  var pairs: TArray<(integer, integer)> := [(1, 2), (3, 4)];
  if pairs[1]._2 <> 4 then halt(6);
end.
