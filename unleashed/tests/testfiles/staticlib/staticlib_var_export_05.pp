{ %PRELIB=lstaticlib_var_export_05.pas }
program staticlib_var_export_05;

{$mode unleashed}
{$linklib lstaticlib_var_export_05}

procedure varInit; cdecl; external name 'var_init';
procedure varDone; cdecl; external name 'var_done';
function varLevelTimes(n: longint): longint; cdecl; external name 'var_level_times';

var
  varLevel: longint; external name 'var_level';

begin
  // initialized data needs no runtime
  if varLevel <> 7 then halt(1);
  varLevel := 5;
  varInit;
  if varLevelTimes(3) <> 15 then halt(2);
  varDone;
  writeln('ok');
end.
