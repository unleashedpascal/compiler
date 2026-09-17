{ %FAIL %EXPECTMSG="`autofree` target must be a local variable" }
program autofree_fail_out_param_01;

{$mode unleashed}

uses Classes;

procedure make(out list: TStringList);
begin
  // the caller's variable would be freed and nilled on exit
  list := autofree TStringList.Create;
end;

var
  l: TStringList;

begin
  make(l);
end.
