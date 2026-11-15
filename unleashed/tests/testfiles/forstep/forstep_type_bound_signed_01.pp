program forstep_type_bound_signed_01;

{$mode unleashed}

begin
  // 100 + 50 does not fit in a shortint
  var visited: array of integer := [];
  for var i: shortint := 0 to 120 step 50 do begin
    visited += [i];
    if Length(visited) > 100 then halt(1);
  end;
  if Length(visited) <> 3 then halt(2);
  if visited[2] <> 100 then halt(3);

  // full shortint range: the distance to the bound exceeds high(shortint)
  visited := [];
  for var i: shortint := -128 to 127 step 100 do begin
    visited += [i];
    if Length(visited) > 100 then halt(4);
  end;
  if Length(visited) <> 3 then halt(5);
  if (visited[0] <> -128) or (visited[1] <> -28) or (visited[2] <> 72) then halt(6);

  var count := 0;
  for var i: longint := 0 to high(longint) step 1 shl 30 do begin
    inc(count);
    if count > 100 then halt(7);
  end;
  if count <> 2 then halt(8);
end.
