program inline_vars_destructure_sibling_specializations_01;

{$mode unleashed}

function boxOf<T>(v: T): (value: T; ok: boolean);
begin
  result := (v, true);
end;

begin
  // same names destructured from two specializations in sibling main-block scopes
  var n := 1;
  if n > 0 then begin
    var (cv, hit) := boxOf<integer>(5);
    if (cv <> 5) or not hit then halt(1);
  end else begin
    var (cv, hit) := boxOf<double>(2.5);
    if (cv <> 2.5) or not hit then halt(2);
  end;
  for var k := 1 to 2 do begin
    var (cv, hit) := boxOf<string>('x');
    if (cv <> 'x') or not hit then halt(3);
  end;
  writeln('ok');
end.
