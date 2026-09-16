program try_except_expr_filter_01;

{$mode unleashed}

uses SysUtils;

function Classify(const s: String): String;
begin
  Result := try IntToStr(StrToInt(s))
           except
             on e: EConvertError do 'convert-error'
           else
             'other-error'
           end;
end;

begin
  if Classify('1') <> '1'             then halt(1);
  if Classify('a') <> 'convert-error' then halt(2);
end.
