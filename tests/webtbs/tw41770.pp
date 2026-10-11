program tw41770;

{$mode delphi}

type
  TBase = class
    Value: LongInt;
  end;

  TDerived = class(TBase);

  TGeneric<T: TBase> = class
    Item: T;
  end;

  TWrapper = class
    class procedure Observe<T: TBase>(Box: TGeneric<T>); static;
    class function Echo<T: TBase>(Box: TGeneric<T>): TGeneric<T>; static; overload;
    class function Echo<T>(Value: LongInt): LongInt; static; overload;
  end;

var
  Observed: TBase;

class procedure TWrapper.Observe<T>(Box: TGeneric<T>);
begin
  Observed := Box.Item;
end;

class function TWrapper.Echo<T>(Box: TGeneric<T>): TGeneric<T>;
begin
  Result := Box;
end;

class function TWrapper.Echo<T>(Value: LongInt): LongInt;
begin
  Result := Value + 1;
end;

var
  Box: TGeneric<TDerived>;
  Item: TDerived;
begin
  Box := TGeneric<TDerived>.Create;
  Item := TDerived.Create;
  try
    Item.Value := 41770;
    Box.Item := Item;
    TWrapper.Observe<TDerived>(Box);
    if Observed <> Item then
      Halt(1);
    if TWrapper.Echo<TDerived>(Box) <> Box then
      Halt(2);
    if TWrapper.Echo<TDerived>(10) <> 11 then
      Halt(3);
    if TWrapper.Echo<TDerived>(Box).Item.Value <> 41770 then
      Halt(4);
  finally
    Item.Free;
    Box.Free;
  end;
  writeln('ok');
end.
