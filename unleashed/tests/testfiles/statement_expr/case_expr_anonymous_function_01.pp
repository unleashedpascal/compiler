program case_expr_anonymous_function_01;

{$mode unleashed}

type
  TProcRef = reference to procedure;

var
  called: integer;

function raiser(doRaise: boolean): integer;
begin
  result := 1;
  if doRaise then raise TObject.Create;
end;

procedure test(i, expected: integer);
begin
  called := 0;
  var p: TProcRef := case i of
    1: procedure begin called := 1; end;
    2: procedure begin called := 2; end;
  else
    procedure begin called := 3; end
  end;
  p();
  if called <> expected then halt(10 + i);

  // try-expression: the except branch yields nil, the try branch a procedure
  called := 0;
  p := try
         if raiser(i = 2) = 1 then procedure begin called := 1; end else procedure begin called := 4; end
       except
         on o: TObject do nil;
       else
         nil
       end;
  if i = 2 then
  begin
    if assigned(p) then halt(20 + i);
  end
  else
  begin
    p();
    if called <> 1 then halt(30 + i);
  end;
end;

begin
  test(1, 1);
  test(2, 2);
  test(3, 3);
end.
