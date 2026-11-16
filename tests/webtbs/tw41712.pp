program tw41712;

{$mode delphi}

type
  TTarget = class
    procedure CheckGeneric<T>;
  end;

var
  Expected: TTarget;
  Matches: LongInt;

procedure TTarget.CheckGeneric<T>;
begin
  if Pointer(Self) = Pointer(Expected) then
    Inc(Matches);
end;

var
  Instance: TTarget;
begin
  Instance := TTarget.Create;
  try
    Expected := Instance;
    with Instance do
      CheckGeneric<TObject>;
    if Matches <> 1 then
      Halt(1);
  finally
    Instance.Free;
  end;
end.
