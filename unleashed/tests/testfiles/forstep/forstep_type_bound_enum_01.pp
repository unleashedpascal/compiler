program forstep_type_bound_enum_01;

{$mode unleashed}

type
  TColor = (coRed, coGreen, coBlue, coCyan, coWhite);

begin
  var count := 0;
  var last := coRed;
  for var e: TColor := coRed to coWhite step 3 do begin
    inc(count);
    last := e;
    if count > 100 then halt(1);
  end;
  if count <> 2 then halt(2);
  if last <> coCyan then halt(3);

  count := 0;
  for var e: TColor := coWhite downto coRed step 2 do begin
    inc(count);
    last := e;
    if count > 100 then halt(4);
  end;
  if count <> 3 then halt(5);
  if last <> coRed then halt(6);
end.
