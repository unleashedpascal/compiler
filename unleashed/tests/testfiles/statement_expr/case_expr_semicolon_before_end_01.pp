program case_expr_semicolon_before_end_01;

{$mode unleashed}

uses SysUtils;

begin
  // a semicolon after the last branch is optional before end
  var s := case 3 of
    1: 'one';
  else
    'other';
  end;
  if s <> 'other' then halt(1);

  s := try IntToStr(StrToInt('x')) except 'err'; end;
  if s <> 'err' then halt(2);

  s := try IntToStr(StrToInt('x')) except on e: EConvertError do 'convert'; else 'other'; end;
  if s <> 'convert' then halt(3);

  var b := true;
  s := case b of
    false: 'f';
    true: 't'
  end;
  if s <> 't' then halt(4);
end.
