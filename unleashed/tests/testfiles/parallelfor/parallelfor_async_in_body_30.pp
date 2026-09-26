program parallelfor_async_in_body_30;
{$mode unleashed}
// `async` and `await` inside a `for parallel` body: the worker routine gets
// the same async lowering as a parsed routine
function sq(a: int64): int64;
begin
  result := a * a;
end;

var
  total: longint;

begin
  var jobs: array of future of int64;
  SetLength(jobs, 8);
  for parallel var i := 0 to 7 do
  begin
    jobs[i] := async sq(i);
    var inner := async sq(i + 1);
    InterlockedExchangeAdd(total, await inner);
  end;
  var sum: int64 := 0;
  for var i := 0 to 7 do
    sum += await jobs[i];
  if sum <> 140 then halt(1);
  if total <> 204 then halt(2);

  var flags: array of future;
  SetLength(flags, 4);
  var hits: longint := 0;
  for parallel var i := 0 to 3 do
    flags[i] := async begin InterlockedIncrement(hits); end;
  for var i := 0 to 3 do
    await flags[i];
  if hits <> 4 then halt(3);
end.
