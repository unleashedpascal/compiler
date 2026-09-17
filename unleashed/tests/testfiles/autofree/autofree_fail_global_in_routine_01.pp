{ %FAIL %EXPECTMSG="`autofree` target must be a local variable" }
program autofree_fail_global_in_routine_01;

{$mode unleashed}

uses Classes;

var
  list: TStringList;

procedure run;
begin
  // a global outlives the routine, so routine-scoped cleanup is rejected
  list := autofree TStringList.Create;
end;

begin
  run;
end.
