library lstaticlib_var_export_05;

{$mode unleashed}

var
  level: longint = 7;

function varLevelTimes(n: longint): longint; cdecl;
begin
  result := level*n;
end;

exports
  rtlInit name 'var_init',
  rtlDone name 'var_done',
  // an exported variable is renamed to the export name in the archive
  level name 'var_level',
  varLevelTimes name 'var_level_times';

begin
end.
