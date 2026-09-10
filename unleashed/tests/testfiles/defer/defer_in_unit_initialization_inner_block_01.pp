{ %PRECOMPILE=udefer_in_unit_initialization_inner_block_01.pas }
program defer_in_unit_initialization_inner_block_01;

{$mode unleashed}

uses udefer_in_unit_initialization_inner_block_01;

begin
  // the nested block kept its own defer scope
  if trace <> 'block-end;inner;' then halt(2);
  trace := trace + 'main;';
end.
