program try_except_expr_set_constructor_01;

{$mode unleashed}

uses sysutils;

type
  TShade = (shLow, shMid, shHigh);
  TShades = set of TShade;

function boom: TShade;
begin
  raise Exception.Create('nope');
end;

var
  s: TShades;
begin
  s := try [shMid] except [] end;
  if s <> [shMid] then halt(1);
  s := try [boom] except [] end;
  if s <> [] then halt(2);
end.
