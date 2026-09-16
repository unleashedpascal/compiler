program if_expr_with_try_inside_01;

{$mode unleashed}

uses SysUtils;

function Format_(use_safe: Boolean; s: String): Integer;
begin
  Result := if use_safe then
              try StrToInt(s) except -1 end
            else
              StrToInt(s);   // unsafe path: lets exception propagate
end;

begin
  if Format_(true, '7')   <> 7  then halt(1);
  if Format_(true, 'no')  <> -1 then halt(2);

  var caught := false;
  try
    Format_(false, 'no');
  except
    on E: Exception do caught := true;
  end;
  if not caught then halt(3);
end.
