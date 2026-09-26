program tuple_literal_anon_proc_inferred_01;

{$mode unleashed}

// a tuple literal holding an anonymous procedure that meets no declared type
// infers a `reference to` field, like an inline var does; the inferred tuple
// still converts to a record with a `reference to` field
type
  TRef = record
    name: string;
    run: reference to procedure(n: integer);
  end;

var
  seen: integer;

begin
  var k := 40;

  var t := (name: 'b', run: procedure(n: integer) begin seen := n * k; end);
  t.run(3);
  if seen <> 120 then halt(1);

  var u := ('c', function(n: integer): integer begin result := n - k; end);
  if u[1](4) <> -36 then halt(2);
  if u[0] <> 'c' then halt(3);

  var r: TRef;
  r := t;
  r.run(5);
  if seen <> 200 then halt(4);
end.
