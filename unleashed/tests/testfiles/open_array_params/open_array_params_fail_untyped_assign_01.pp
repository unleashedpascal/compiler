{ %FAIL %EXPECTMSG="Assignments to formal parameters and open arrays are not possible" }
program open_array_params_fail_untyped_assign_01;
{$mode unleashed}

// an untyped parameter keeps the formal-parameter wording

procedure stamp(var buf);
begin
  buf := 1;
end;

begin
end.
