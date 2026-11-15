program forstep_type_bound_64bit_01;

{$mode unleashed}

begin
  var visited: array of int64 := [];
  for var i: int64 := low(int64) to high(int64) step high(int64) do begin
    visited += [i];
    if Length(visited) > 100 then halt(1);
  end;
  if Length(visited) <> 3 then halt(2);
  if (visited[0] <> low(int64)) or (visited[1] <> -1) or (visited[2] <> high(int64)-1) then halt(3);

  var count := 0;
  var last: qword := 0;
  for var i: qword := 0 to high(qword) step qword(1) shl 63 do begin
    inc(count);
    last := i;
    if count > 100 then halt(4);
  end;
  if count <> 2 then halt(5);
  if last <> qword(1) shl 63 then halt(6);

  count := 0;
  for var i: qword := high(qword) downto 0 step qword(1) shl 63 do begin
    inc(count);
    if count > 100 then halt(7);
  end;
  if count <> 2 then halt(8);
end.
