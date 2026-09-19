program tuple_literal_into_record_members_01;

{$mode unleashed}

// a tuple literal converts to a record by its instance fields alone;
// methods, class vars and nested types of the target do not count

type
  TPair = record
    x, y: integer;
    function sum: integer;
  end;

  TCounted = record
    class var count: integer;
    var a, b: integer;
  end;

  TNested = record
  type
    TInner = integer;
  var
    lo, hi: TInner;
  end;

  TLabeled = record
    name: string;
    value: double;
    function show: string;
  end;

function intToStr(v: integer): string;
begin
  str(v, result);
end;

function TPair.sum: integer;
begin
  result := x+y;
end;

function TLabeled.show: string;
begin
  result := name+'='+intToStr(trunc(value));
end;

function makePair: TPair;
begin
  result := (2, 3);
end;

begin
  var p: TPair := (5, 6);
  if p.sum <> 11 then halt(1);

  var c: TCounted := (7, 8);
  if c.a+c.b <> 15 then halt(2);

  var n: TNested := (lo: 1, hi: 2);
  if n.lo+n.hi <> 3 then halt(3);

  // field-by-field conversion: integer literal into a double field
  var l: TLabeled := ('pi', 3);
  if l.show <> 'pi=3' then halt(4);

  if makePair.sum <> 5 then halt(5);

  var (u, v) := makePair;
  if (u <> 2) or (v <> 3) then halt(6);

  (p.x, p.y) := (p.y, p.x);
  if (p.x <> 6) or (p.y <> 5) then halt(7);

  writeln('ok');
end.
