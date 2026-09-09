program implicit_generics_not_before_call_01;

{$mode unleashed}

type
  TArr<T> = array of T;

function hasIn<T>(const xs: TArr<T>; const v: T): boolean;
begin
  result := false;
  for var i := 0 to high(xs) do if xs[i] = v then exit(true);
end;

function missing<T>(const a, b: TArr<T>): integer;
begin
  result := 0;
  for var i := 0 to high(a) do if not hasIn<T>(b, a[i]) then result += 1;
end;

begin
  var x: TArr<integer> := [1, 2, 3];
  if not hasIn<integer>(x, 9) then writeln('absent');
  var b := not hasIn<integer>(x, 2);
  if b then halt(1);
  // `not` binds tighter than the comparison
  if (not hasIn<integer>(x, 9)) <> true then halt(2);
  if not hasIn<integer>(x, 9) = false then halt(3);
  if missing<integer>(x, [2, 3, 4]) <> 1 then halt(4);
  writeln('ok');
end.
