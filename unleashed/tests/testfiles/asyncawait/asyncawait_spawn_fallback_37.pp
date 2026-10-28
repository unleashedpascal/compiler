program asyncawait_spawn_fallback_37;
{$mode unleashed}
// when the OS cannot create a worker thread the work runs on the caller:
// every future still completes and its await returns the right value.
// 200 futures alive at once exhaust thread creation on 32-bit Windows,
// where an await used to block forever on the futures that got no thread
uses SysUtils;

function slow(x: Integer): Integer;
begin
  Sleep(50);
  result := x * 3;
end;

begin
  var futures: array[200] of future of Integer;
  for var i := 0 to 199 do
    futures[i] := async slow(i);
  var sum := 0;
  for var i := 0 to 199 do
    sum += await futures[i];
  if sum <> 59700 then halt(1);
end.
