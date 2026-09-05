{ %FAIL %EXPECTMSG="Cannot assign to an open array parameter, declare it as TArray<T> or a dynamic array type to replace its contents" }
program open_array_params_fail_assign_01;
{$mode unleashed}

// assigning a whole array to an `array of T` parameter reports that the
// parameter is an open array; the formal-parameter wording stays for
// untyped parameters

function replace(out q: array of string): boolean;
begin
  var loc: array of string := ['a'];
  q := loc;
  result := true;
end;

begin
end.
