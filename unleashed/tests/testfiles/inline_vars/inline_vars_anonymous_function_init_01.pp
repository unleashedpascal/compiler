program inline_vars_anonymous_function_init_01;

{$mode unleashed}

type
  TIntFn = reference to function(x: integer): integer;

function add(a, b: integer): integer;
begin
  result := a + b;
end;

function applyTwice(f: TIntFn; v: integer): integer;
begin
  result := f(f(v));
end;

begin
  // explicit function reference type
  var f1: reference to function(a, b: integer): integer := function(a, b: integer): integer begin result := a + b; end;
  if f1(1, 2) <> 3 then halt(1);

  // explicit anonymous procvar type, anonymous function and a routine address
  var f2: function(a, b: integer): integer := function(a, b: integer): integer begin result := a * b; end;
  if f2(3, 4) <> 12 then halt(2);
  var f3: function(a, b: integer): integer := @add;
  if f3(5, 6) <> 11 then halt(3);
  var f4: function(a, b: integer): integer;
  f4 := function(a, b: integer): integer begin result := a - b; end;
  if f4(9, 2) <> 7 then halt(4);

  // inferred: an anonymous function gives a function reference
  var f5 := function(a, b: integer): integer begin result := a + b; end;
  if f5(20, 22) <> 42 then halt(5);

  // the inferred reference captures like a declared one
  var base := 100;
  var f6 := function(x: integer): integer begin result := x + base; end;
  base := 200;
  if f6(1) <> 201 then halt(7);
  if applyTwice(f6, 1) <> 401 then halt(8);

  var p := procedure begin base := 0; end;
  p();
  if base <> 0 then halt(9);

  writeln('ok');
end.
