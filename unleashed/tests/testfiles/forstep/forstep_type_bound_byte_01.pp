program forstep_type_bound_byte_01;

{$mode unleashed}

begin
  // the last step lands exactly on the bound; the next one would wrap a byte
  var count := 0;
  var last := 0;
  for var i: byte := 0 to 250 step 50 do begin
    inc(count);
    last := i;
    if count > 100 then halt(1);
  end;
  if count <> 6 then halt(2);
  if last <> 250 then halt(3);

  // the bound is high(byte), so i > bound can never become true
  count := 0;
  for var i: byte := 0 to 255 step 55 do begin
    inc(count);
    last := i;
    if count > 100 then halt(4);
  end;
  if count <> 5 then halt(5);
  if last <> 220 then halt(6);

  // the same with the step read from a variable
  var step: byte := 55;
  count := 0;
  for var i: byte := 0 to 255 step step do begin
    inc(count);
    if count > 100 then halt(7);
  end;
  if count <> 5 then halt(8);
end.
