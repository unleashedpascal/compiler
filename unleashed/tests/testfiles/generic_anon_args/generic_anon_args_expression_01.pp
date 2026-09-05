program generic_anon_args_expression_01;
{$mode unleashed}

// anonymous arguments in inline specializations inside expressions: a
// constructor call, a generic routine call and a typecast

type
  TBox<T> = class
    value: T;
  end;

function makePair<A, B>(x: A; y: B): (A, B);
begin
  result := (x, y);
end;

var arr: array of (integer, string);

begin
  var b := TBox<(a: integer; b: string)>.Create;
  b.value := (1, 'one');
  var c: TBox<(a: integer; b: string)> := b;
  if c.value.b <> 'one' then halt(1);
  b.Free;
  var p := makePair<(integer, string), integer>((2, 'two'), 3);
  if (p._1._2 <> 'two') or (p._2 <> 3) then halt(2);
  arr := [(4, 'four')];
  var t := TArray<(integer, string)>(arr);
  if t[0]._2 <> 'four' then halt(3);
  var d := TBox<array of string>.Create;
  d.value := ['x', 'y'];
  if d.value[1] <> 'y' then halt(4);
  d.Free;
end.
