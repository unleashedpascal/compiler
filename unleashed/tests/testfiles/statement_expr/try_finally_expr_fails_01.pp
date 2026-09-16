{ %FAIL }
program try_finally_expr_fails_01;

{$mode unleashed}

var
  s: string;
begin
  // only try..except has an expression form
  s := try 'x' finally writeln('f'); end;
end.
