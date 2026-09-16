program match_expr_with_otherwise_01;

{$mode unleashed}

procedure main;
begin
  var x := 33;
  var s := match x of
    0..4: 'one';
       2: 'two';
  otherwise 'wild' end;
  if s <> 'wild' then halt(1);
  x := 1;
  s := match x of
    0..4: 'one';
       2: 'two';
  otherwise 'wild' end;
  if s <> 'one' then halt(2);
end;

begin
  main;
end.
