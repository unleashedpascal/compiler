program if_expr_anonymous_function_01;

{$mode unleashed}

type
  TIntFunc = reference to function(a: integer): integer;
  TProc = procedure;

var
  called: integer;

function pick(flag: boolean): TIntFunc;
begin
  // each branch is an anonymous function; the block gets its type from the
  // function reference it is assigned to
  result := if flag then
              function(a: integer): integer begin result := a + 1; end
            else
              function(a: integer): integer begin result := a * 2; end;
end;

procedure run(const p: TIntFunc);
begin
  called := p(10);
end;

begin
  if pick(true)(10) <> 11 then halt(1);
  if pick(false)(10) <> 20 then halt(2);

  // capture of a local through the reference
  var base := 100;
  var f: TIntFunc := if base > 50 then
                       function(a: integer): integer begin result := a + base; end
                     else
                       function(a: integer): integer begin result := a - base; end;
  if f(1) <> 101 then halt(3);

  // as an argument
  run(if base = 100 then
        function(a: integer): integer begin result := 7; end
      else
        function(a: integer): integer begin result := 8; end);
  if called <> 7 then halt(4);

  // plain procedural variable target
  var p: TProc := if base = 100 then
                    procedure begin called := 3; end
                  else
                    procedure begin called := 4; end;
  p();
  if called <> 3 then halt(5);
end.
