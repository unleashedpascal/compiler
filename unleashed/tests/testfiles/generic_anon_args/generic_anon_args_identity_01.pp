program generic_anon_args_identity_01;
{$mode unleashed}

// the same shape written twice in one module names one specialization: a
// generic class instance declared with one spelling is assignable to a
// variable declared with the other, and var parameters bind directly

type
  TBox<T> = class
    value: T;
  end;

  TPairBox = TBox<(a: integer; b: string)>;

procedure grow(var q: TArray<(a: integer; b: string)>);
begin
  setlength(q, length(q) + 1);
  q[high(q)] := (9, 'nine');
end;

var
  b1: TBox<(a: integer; b: string)>;
  b2: TPairBox;
  items: TArray<(a: integer; b: string)>;
  rows: TArray<array of string>;

procedure addRow(var r: TArray<array of string>);
begin
  setlength(r, 1);
  r[0] := ['q'];
end;

begin
  b1 := TBox<(a: integer; b: string)>.Create;
  b1.value := (1, 'one');
  b2 := b1;
  if b2.value.b <> 'one' then halt(1);
  b1.Free;
  items := [(7, 'seven')];
  grow(items);
  if (length(items) <> 2) or (items[1].a <> 9) then halt(2);
  addRow(rows);
  if rows[0][0] <> 'q' then halt(3);
end.
