program try_except_expr_in_match_branch_01;

{$mode unleashed}

uses SysUtils;

function Parse(kind: Integer; s: String): Integer;
begin
  match kind of
    1: Result := try StrToInt(s) except 0 end;
    2: Result := try StrToInt(s) * 2 except -1 end;
    _: Result := -99;
  end;
end;

begin
  if Parse(1, '42')  <> 42  then halt(1);
  if Parse(1, 'xyz') <> 0   then halt(2);
  if Parse(2, '5')   <> 10  then halt(3);
  if Parse(2, 'no')  <> -1  then halt(4);
  if Parse(7, '0')   <> -99 then halt(5);
end.
