{ %OPT=-O3 }
program forstep_opt_strength_01;

{$mode unleashed}

var
  values: array[100] of integer;

procedure run;
begin
  for var j := 0 to 99 do values[j] := j;

  // a multiple of the counter is what strength reduction rewrites
  var sum := 0;
  for var i := 0 to 20 step 5 do sum += i*7;
  if sum <> 350 then halt(1);

  sum := 0;
  for var k := 0 to 99 step 10 do sum += values[k];
  if sum <> 450 then halt(2);

  sum := 0;
  for var k := 99 downto 0 step 10 do sum += values[k];
  if sum <> 540 then halt(3);

  sum := 0;
  for var k := 90 downto 0 step 30 do sum += k*3;
  if sum <> 540 then halt(4);
end;

begin
  run;
end.
