program try_except_expr_01;

{$mode unleashed}

uses SysUtils;

function ParseSafe(const s: String): Integer;
begin
  Result := try StrToInt(s) except -1 end;
end;

begin
  if ParseSafe('42')   <> 42  then halt(1);
  if ParseSafe('xyz')  <> -1  then halt(2);
  if ParseSafe('-100') <> -100 then halt(3);
end.
