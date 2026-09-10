{ %PRECOMPILE=udefer_in_unit_initialization_01.pas }
program defer_in_unit_initialization_01;

{$mode unleashed}

uses udefer_in_unit_initialization_01;

begin
  trace := trace + 'main;';
  if trace <> 'init;main;' then halt(3);
end.
