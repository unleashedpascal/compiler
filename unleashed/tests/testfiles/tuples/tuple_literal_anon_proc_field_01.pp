program tuple_literal_anon_proc_field_01;

{$mode unleashed}

// an anonymous procedure as a tuple literal field binds to the field type
// of the record or tuple the literal converts to, a plain procedural
// variable or a `reference to` type, captures included
type
  TCmd = record
    name: string;
    run: procedure(n: integer);
  end;

  TRef = record
    name: string;
    run: reference to procedure(n: integer);
  end;

var
  seen: integer;

procedure take(const c: TCmd);
begin
  c.run(7);
end;

function make: TCmd;
begin
  result := (name: 'm', run: procedure(n: integer) begin seen := n * 100; end);
end;

begin
  var k := 40;
  var c: TCmd;
  c := (name: 'a', run: procedure(n: integer) begin seen := n + k; end);
  c.run(2);
  if seen <> 42 then halt(1);

  var r: TRef;
  r := (name: 'b', run: procedure(n: integer) begin seen := n * k; end);
  r.run(3);
  if seen <> 120 then halt(2);

  take((name: 't', run: procedure(n: integer) begin seen := n - k; end));
  if seen <> -33 then halt(3);

  make.run(5);
  if seen <> 500 then halt(4);

  var cmds: array of TCmd;
  cmds := [(name: 'x', run: procedure(n: integer) begin seen := n; end),
           (name: 'y', run: procedure(n: integer) begin seen := -n; end)];
  cmds[0].run(8);
  if seen <> 8 then halt(5);
  cmds[1].run(9);
  if seen <> -9 then halt(6);
end.
