unit ucomposable_records_class_enum_ppu_01;

{$mode unleashed}

interface

type
  TShape = class
  type
    TKind = (skDot, skLine, skBox);
  var
    kind: TKind;
    function kindIndex: Integer;
  end;

implementation

function TShape.kindIndex: Integer;
begin
  Result := Ord(kind);
end;

end.
