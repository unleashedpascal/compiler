unit uppu_reload_01_side;

{$mode unleashed}

interface

uses uppu_reload_01_cycle;

function sideValue(var c: TCycle): integer;

implementation

function sideValue(var c: TCycle): integer;
begin
  result := c.v+7;
end;

end.
