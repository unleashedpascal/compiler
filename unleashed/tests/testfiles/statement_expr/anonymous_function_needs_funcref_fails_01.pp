{ %FAIL }
program anonymous_function_needs_funcref_fails_01;

{$mode unleashed}

var
  p: pointer;
  b: boolean;
begin
  b := true;
  // anonymous function branches only convert to a procedural variable or a
  // function reference
  p := if b then procedure begin end else procedure begin end;
end.
