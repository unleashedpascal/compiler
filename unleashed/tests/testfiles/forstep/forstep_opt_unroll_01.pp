{ %OPT=-O3 }
program forstep_opt_unroll_01;

{$mode unleashed}

var
  i: integer;

begin
  // constant bounds and a tiny body are what the loop unroller picks up
  var sum := 0;
  for i := 1 to 10 step 4 do sum += i;
  if sum <> 15 then halt(1);

  sum := 0;
  for i := 20 downto 1 step 3 do sum += i;
  if sum <> 77 then halt(2);

  var count := 0;
  for var j := 0 to 7 step 2 do count += j;
  if count <> 12 then halt(3);
end.
