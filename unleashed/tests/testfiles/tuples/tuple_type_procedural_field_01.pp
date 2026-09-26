program tuple_type_procedural_field_01;

{$mode unleashed}

// a `reference to` or procedural field in a tuple type is finished like a
// record field: it converts from a matching variable or anonymous function
// and can be called
type
  TP = (x: integer; f: reference to function(a: integer): integer);
  TQ = (integer, function(a: integer): integer);
  TObj = class
    base: integer;
    function add(a: integer): integer;
  end;
  TM = (name: string; m: function(a: integer): integer of object);

function TObj.add(a: integer): integer;
begin
  result := base + a;
end;

function twice(a: integer): integer;
begin
  result := a * 2;
end;

var
  p: TP;
  q: TQ;
  m: TM;
  g: reference to function(a: integer): integer;

begin
  g := function(a: integer): integer begin result := a + 1; end;
  p := (10, g);
  if p.f(p.x) <> 11 then halt(1);

  p := (20, function(a: integer): integer begin result := a - 1; end);
  if p.f(p.x) <> 19 then halt(2);

  q := (5, @twice);
  if q[1](q[0]) <> 10 then halt(3);

  var o := TObj.Create;
  o.base := 100;
  m := (name: 'o', m: @o.add);
  if m.m(7) <> 107 then halt(4);
  o.Free;
end.
