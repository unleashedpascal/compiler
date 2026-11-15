{ %OPT=-O3 }
{ a for loop over the whole range of a 64 bit counter runs 2^64 times; the
  loop unroller must not try to store that count }
program tw42097;

{$mode objfpc}

{$ifdef CPU64}
var
  q: qword;
  i: int64;
  count: longint;
{$endif CPU64}

begin
{$ifdef CPU64}
  count := 0;
  for q := 0 to high(qword) do begin
    inc(count);
    if count = 3 then
      break;
  end;
  if count <> 3 then
    halt(1);

  count := 0;
  for i := high(int64) downto low(int64) do begin
    inc(count);
    if count = 3 then
      break;
  end;
  if count <> 3 then
    halt(2);
{$endif CPU64}
end.
