unit udefer_in_unit_initialization_01;

{$mode unleashed}

interface

var
  trace: String = '';

implementation

initialization
  trace := trace + 'init;';
  // registered first, so it runs last
  defer if trace <> 'init;main;final;defer2;defer1;' then ExitCode := 1;
  defer trace := trace + 'defer1;';
  defer trace := trace + 'defer2;';

finalization
  trace := trace + 'final;';
  // the deferred statements have not run yet
  if trace <> 'init;main;final;' then ExitCode := 2;

end.
