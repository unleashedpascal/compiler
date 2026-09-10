unit uautofree_in_unit_finalization_01;

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
  defer if trace <> 'main;final;destroy;' then ExitCode := 1;

finalization
  obj := autofree TTracker.Create;
  trace := trace + 'final;';

end.
