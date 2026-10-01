{ %FAIL %NORUN }
program match_expr_all_branches_empty_01;
{$mode unleashed}

// match-as-expression where no branch yields a value must report an error
// instead of crashing the compiler
function foo(n: integer): string;
begin
  result := match n of
    _: ;
  end;
end;

begin
end.
