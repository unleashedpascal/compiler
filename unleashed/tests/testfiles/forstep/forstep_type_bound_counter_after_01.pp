program forstep_type_bound_counter_after_01;

{$mode unleashed}

var
  i: byte;

begin
  // the counter still advances past the bound on a natural exit
  for i := 0 to 200 step 50 do ;
  if i <> 250 then halt(1);

  // here the value past the bound does not fit, so the counter wraps
  for i := 0 to 250 step 50 do ;
  if i <> 44 then halt(2);
end.
