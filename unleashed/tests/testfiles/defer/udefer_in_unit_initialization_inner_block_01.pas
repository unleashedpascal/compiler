unit udefer_in_unit_initialization_inner_block_01;

{$mode unleashed}

interface

var
  trace: String = '';

implementation

initialization
  defer if trace <> 'block-end;inner;main;outer;' then ExitCode := 1;
  begin
    defer trace := trace + 'inner;';
    trace := trace + 'block-end;';
  end;
  defer trace := trace + 'outer;';

end.
