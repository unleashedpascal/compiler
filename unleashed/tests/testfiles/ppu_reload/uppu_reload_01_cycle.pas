unit uppu_reload_01_cycle;

{$mode unleashed}

interface

type
  TCycle = class
    v: integer;
  end;

function cycleValue: integer;

implementation

uses uppu_reload_01_root;

function cycleValue: integer;
begin
  result := rootValue;
end;

end.
