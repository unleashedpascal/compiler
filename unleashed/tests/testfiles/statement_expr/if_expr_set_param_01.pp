program if_expr_set_param_01;

{$mode unleashed}

type
  TShade = (shLow, shMid, shHigh);
  TShades = set of TShade;

function count(s: TShades): integer;
var
  sh: TShade;
begin
  result := 0;
  for sh in s do
    inc(result);
end;

var
  flag: boolean;
begin
  // statement expression passed as a set-typed parameter
  flag := true;
  if count(if flag then [shLow, shHigh] else []) <> 2 then halt(1);
  flag := false;
  if count(if flag then [shLow, shHigh] else []) <> 0 then halt(2);
  if count(case ord(flag) of 0: [shMid]; else [] end) <> 1 then halt(3);
end.
