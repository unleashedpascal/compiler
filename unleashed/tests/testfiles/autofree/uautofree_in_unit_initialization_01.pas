unit uautofree_in_unit_initialization_01;

{$mode unleashed}

interface

type
  TTracker = class
    destructor Destroy; override;
  end;

var
  obj: TTracker;
  trace: String = '';

implementation

destructor TTracker.Destroy;
begin
  trace := trace + 'destroy;';
  inherited;
end;

initialization
  // registered first, so it runs after the disposal below
  defer if (trace <> 'main;final;destroy;') or assigned(obj) then ExitCode := 1;
  obj := autofree TTracker.Create;

finalization
  trace := trace + 'final;';
  // the object outlives the initialization section
  if not assigned(obj) then ExitCode := 2;

end.
