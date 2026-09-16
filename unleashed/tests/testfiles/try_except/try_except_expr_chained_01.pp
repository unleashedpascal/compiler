program try_except_expr_chained_01;

{$mode unleashed}

uses SysUtils;

function ParseChain(const s: String): Integer;
begin
  // try-except expression chained inside if-expression chain
  Result := if s = '' then -1
            else try StrToInt(s) except -2 end;
end;

begin
  if ParseChain('')    <> -1 then halt(1);
  if ParseChain('42')  <> 42 then halt(2);
  if ParseChain('xyz') <> -2 then halt(3);
end.
