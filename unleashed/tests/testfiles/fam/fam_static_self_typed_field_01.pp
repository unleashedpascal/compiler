program fam_static_self_typed_field_01;

{ a class var of the record's own type is not the last layout field, so
  the FAM check must not recurse into the record through it }

{$mode unleashed}

type
  TPoint = record
    x, y: integer;
    class var origin: TPoint;
    class function make(ax, ay: integer): TPoint; static;
  end;

class function TPoint.make(ax, ay: integer): TPoint;
begin
  result.x := ax;
  result.y := ay;
end;

begin
  TPoint.origin := TPoint.make(0, 0);
  var p := TPoint.make(3, 4);
  if p.x + p.y <> 7 then halt(1);
  if TPoint.origin.x <> 0 then halt(2);
end.
