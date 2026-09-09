program async_open_array_arg_01;

{$mode unleashed}

function firstOf(const xs: array of integer): integer;
begin
  result := xs[0];
end;

function sumOf(xs: array of integer): integer;
begin
  result := 0;
  for var i := 0 to high(xs) do result += xs[i];
end;

begin
  // a dynamic array, a static array and an array literal all snapshot by value
  var dyn: array of integer := [7, 8];
  var st: array[0..2] of integer := [1, 2, 3];
  var j1 := async firstOf(dyn);
  var j2 := async sumOf(st);
  var j3 := async sumOf([100, 200, 300]);
  if await j1 <> 7 then halt(1);
  if await j2 <> 6 then halt(2);
  if await j3 <> 600 then halt(3);
  writeln('ok');
end.
