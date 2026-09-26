{ %fail }
{$mode delphi}

{ A valid implementation header must not erase the declaration's constraint
  when a concrete specialization is later requested. }
type
  TBase = class end;
  TBox<T: TBase> = class end;
  TWrapper = class
    class procedure Observe<T: TBase>(Box: TBox<T>); static;
  end;

class procedure TWrapper.Observe<T>(Box: TBox<T>);
begin
end;

begin
  TWrapper.Observe<TObject>(nil);
end.
