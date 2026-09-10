unit udefer_in_unit_initialization_no_final_01;

{$mode unleashed}

interface

var
  trace: String = '';

implementation

initialization
  trace := trace + 'init;';
  defer if trace <> 'init;main;' then ExitCode := 1;

end.
