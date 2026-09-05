{ %FAIL %EXPECTMSG="Cannot resize an open array parameter, declare it as TArray<T> or a dynamic array type" }
program open_array_params_fail_setlength_01;
{$mode unleashed}

// SetLength on an `array of T` parameter reports that the parameter is an
// open array, not a plain type mismatch

function grow(out q: array of string): boolean;
begin
  setlength(q, 1);
  result := true;
end;

begin
end.
