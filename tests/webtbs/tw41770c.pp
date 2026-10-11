{ %fail }
{$mode delphi}

{ Matching a name and generic arity is only a reason to defer constraints;
  the complete routine signature must still match its declaration. }
type
  TBase = class end;
  TBox<T: TBase> = class end;
  TWrapper = class
    class function Echo<T: TBase>(Box: TBox<T>): TBox<T>; static;
  end;

class function TWrapper.Echo<T>(Box: TBox<T>): TBase;
begin
  Result := nil;
end;

begin
end.
