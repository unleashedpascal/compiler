program inline_vars_named_record_tuple_init_01;

{$mode unleashed}

type
  TCode = record
    prefix: string;
    serial: integer;
  end;

  TPair = (integer, integer);

begin
  // positional tuple literal into an explicitly typed inline var
  var a: TCode := ('AB', 41);
  if (a.prefix <> 'AB') or (a.serial <> 41) then halt(1);

  // named tuple literal
  var b: TCode := (prefix: 'CD', serial: 7);
  if (b.prefix <> 'CD') or (b.serial <> 7) then halt(2);

  // aggregate form still goes through the typed constant parser
  var c: TCode := (prefix: 'EF'; serial: 9);
  if (c.prefix <> 'EF') or (c.serial <> 9) then halt(3);

  // named tuple type alias
  var p: TPair := (3, 4);
  if (p[0] <> 3) or (p[1] <> 4) then halt(4);

  // parenthesized expression is still an expression
  var n: integer := (5 + 3);
  if n <> 8 then halt(5);

  writeln('ok');
end.
