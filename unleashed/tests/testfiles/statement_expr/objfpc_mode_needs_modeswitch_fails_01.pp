{ %FAIL }
program objfpc_mode_needs_modeswitch_fails_01;

{ statement expressions are off by default outside unleashed and delphi }
{$mode objfpc}

var
  s: string;
begin
  s := if 0 < 1 then 'foo' else 'bar';
end.
