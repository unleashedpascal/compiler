program forstep_type_bound_downto_01;

{$mode unleashed}

begin
  // the bound is low(byte), so i < bound can never become true
  var count := 0;
  var last := 0;
  for var i: byte := 255 downto 0 step 50 do begin
    inc(count);
    last := i;
    if count > 100 then halt(1);
  end;
  if count <> 6 then halt(2);
  if last <> 5 then halt(3);

  // crossing zero in a signed type, then stopping before low(shortint)
  var visited: array of integer := [];
  for var j: shortint := 127 downto -128 step 100 do begin
    visited += [j];
    if Length(visited) > 100 then halt(4);
  end;
  if Length(visited) <> 3 then halt(5);
  if (visited[0] <> 127) or (visited[1] <> 27) or (visited[2] <> -73) then halt(6);
end.
