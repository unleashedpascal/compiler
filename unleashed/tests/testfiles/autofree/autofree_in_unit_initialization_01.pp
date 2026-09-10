{ %PRECOMPILE=uautofree_in_unit_initialization_01.pas }
program autofree_in_unit_initialization_01;

{$mode unleashed}

uses uautofree_in_unit_initialization_01;

begin
  if not assigned(obj) then halt(3);
  trace := trace + 'main;';
end.
