unit uppu_reload_01_root;

{$mode unleashed}

interface

uses uppu_reload_01_side;

{$ifdef PPU_RELOAD_01_EXTRA}
var
  rootExtra: integer;
{$endif}

function rootValue: integer;

implementation

uses uppu_reload_01_cycle;

function rootValue: integer;
begin
  var c := TCycle.Create;
  defer c.Free;
  result := sideValue(c);
end;

end.
