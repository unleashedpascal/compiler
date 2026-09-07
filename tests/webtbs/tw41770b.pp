{ %fail }
{$mode delphi}

{ The deferral belongs to implementation headers, not arbitrary
  specializations appearing in the implementation body. }
type
  TBase = class end;
  TBox<T: TBase> = class end;
  TWrapper = class
    class procedure Observe<T: TBase>(Box: TBox<T>); static;
  end;

class procedure TWrapper.Observe<T>(Box: TBox<T>);
var
  Invalid: TBox<TObject>;
begin
  Invalid := nil;
end;

begin
end.
