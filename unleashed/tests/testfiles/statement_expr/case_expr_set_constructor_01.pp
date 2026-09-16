program case_expr_set_constructor_01;

{$mode unleashed}

type
  TShade = (shLow, shMid, shHigh);
  TShades = set of TShade;

var
  s: TShades;
  k: integer;
begin
  k := 1;
  s := case k of 1: [shHigh]; else [] end;
  if s <> [shHigh] then halt(1);
  k := 2;
  s := case k of 1: [shHigh]; else [] end;
  if s <> [] then halt(2);
  s := case k of 1: [shLow]; 2: [shLow, shMid]; else [] end;
  if s <> [shLow, shMid] then halt(3);
end.
