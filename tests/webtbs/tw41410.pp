program tw41410;

{$mode delphi}

type
  {$M+}
  TContainer = class
  private
    FValue: Integer;
  published
    procedure Ping;
    procedure Test<T>(const AValue: T);
  end;
  {$M-}

procedure TContainer.Ping;
begin
  FValue := 7;
end;

procedure TContainer.Test<T>(const AValue: T);
begin
  FValue := SizeOf(AValue);
end;

var
  Container: TContainer;
begin
  Container := TContainer.Create;
  try
    if Container.MethodAddress('Ping') = nil then
      Halt(1);
    if Container.MethodAddress('Test') <> nil then
      Halt(2);
    Container.Ping;
    if Container.FValue <> 7 then
      Halt(3);
    Container.Test<Int64>(42);
    if Container.FValue <> SizeOf(Int64) then
      Halt(4);
  finally
    Container.Free;
  end;
end.
