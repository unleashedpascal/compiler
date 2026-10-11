program tw41589;

{$mode delphi}

type
  TValue = record
    A, B: LongInt;
  end;

  TValueHelper = record helper for TValue
    procedure SetA(Value: LongInt);
    function Sum: LongInt;
  end;

  THolder = class
  private
    FByField: TValue;
    FByGetter: TValue;
    function GetByGetter: TValue;
  public
    property ByField: TValue read FByField write FByField;
    property ByGetter: TValue read GetByGetter write FByGetter;
  end;

procedure TValueHelper.SetA(Value: LongInt);
begin
  Self.A := Value;
end;

function TValueHelper.Sum: LongInt;
begin
  Result := Self.A + Self.B;
end;

function THolder.GetByGetter: TValue;
begin
  Result := FByGetter;
end;

var
  Holder: THolder;
  V: TValue;
begin
  V.A := 100;
  V.B := 200;
  V.SetA(11);
  if (V.A <> 11) or (V.Sum <> 211) then
    Halt(1);

  Holder := THolder.Create;
  try
    V.A := 100;
    V.B := 200;
    Holder.ByField := V;
    Holder.ByGetter := V;

    if (Holder.ByField.Sum <> 300) or (Holder.ByGetter.Sum <> 300) then
      Halt(2);

    Holder.ByField.SetA(22);
    Holder.ByGetter.SetA(33);
    if (Holder.ByField.A <> 100) or (Holder.ByGetter.A <> 100) then
      Halt(3);
  finally
    Holder.Free;
  end;
end.
