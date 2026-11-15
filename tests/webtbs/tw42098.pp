{ %OPT=-O3 }
{ a for loop with an unused counter is turned into a countdown from the
  number of iterations; that number must fit in the counter's type }
program tw42098;

{$mode objfpc}

procedure run(n, k: byte; m: longint);
var
  b: byte;
  l: longint;
  count: longint;
begin
  { 256 iterations do not fit in a byte }
  count := 0;
  for b := 0 to 255 do
    inc(count);
  if count <> 256 then
    halt(1);

  count := 0;
  for b := 0 to n do
    inc(count);
  if count <> 256 then
    halt(2);

  { empty range, the count would be negative }
  count := 0;
  for b := 10 to k do
    inc(count);
  if count <> 0 then
    halt(3);

  count := 0;
  for l := low(longint) to high(longint) do begin
    inc(count);
    if count = 3 then
      break;
  end;
  if count <> 3 then
    halt(4);

  count := 0;
  for l := low(longint) to m do begin
    inc(count);
    if count = 3 then
      break;
  end;
  if count <> 3 then
    halt(5);

  { these still fit }
  count := 0;
  for b := 1 to n do
    inc(count);
  if count <> 255 then
    halt(6);

  count := 0;
  for b := 0 to 254 do
    inc(count);
  if count <> 255 then
    halt(7);
end;

begin
  run(255, 3, high(longint));
end.
