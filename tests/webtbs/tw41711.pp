program tw41711;

{$mode delphi}

type
  TTarget = class
    procedure CheckPlain;
    procedure CheckGeneric<T>;
    destructor Destroy; override;
  end;

  TOuter = class
    procedure Invoke;
  end;

  TValue = record
    Number: LongInt;
    procedure SetPlain(AValue: LongInt);
    procedure SetGeneric<T>(AValue: LongInt);
  end;

var
  Expected: TTarget;
  Phase: LongInt;
  ExplicitGenericMatches: LongInt;
  WithVariableMatches: LongInt;
  WithExpressionMatches: LongInt;
  PlainWithMatches: LongInt;
  WrongMatches: LongInt;
  DestroyedTargets: LongInt;

procedure TTarget.CheckPlain;
begin
  if Pointer(Self) = Pointer(Expected) then
    Inc(PlainWithMatches)
  else
    Inc(WrongMatches);
end;

procedure TTarget.CheckGeneric<T>;
begin
  if Pointer(Self) <> Pointer(Expected) then
    begin
      Inc(WrongMatches);
      Exit;
    end;
  case Phase of
    1: Inc(ExplicitGenericMatches);
    2: Inc(WithVariableMatches);
    3: Inc(WithExpressionMatches);
  else
    Inc(WrongMatches);
  end;
end;

procedure TValue.SetPlain(AValue: LongInt);
begin
  Self.Number := AValue;
end;

procedure TValue.SetGeneric<T>(AValue: LongInt);
begin
  Self.Number := AValue + SizeOf(T);
end;

destructor TTarget.Destroy;
begin
  Inc(DestroyedTargets);
  inherited;
end;

function MakeTarget: TTarget;
begin
  Result := TTarget.Create;
  Expected := Result;
end;

procedure TOuter.Invoke;
var
  Target: TTarget;
begin
  Target := TTarget.Create;
  try
    Expected := Target;
    Phase := 1;
    Target.CheckGeneric<LongInt>;
    Phase := 2;
    with Target do
      CheckGeneric<LongInt>;
    with Target do
      CheckPlain;
  finally
    Target.Free;
  end;

  Phase := 3;
  with MakeTarget do
    begin
      CheckGeneric<LongInt>;
      Free;
    end;
end;

var
  Outer: TOuter;
  Value: TValue;
begin
  Value.SetGeneric<Word>(20);
  if Value.Number <> 22 then
    Halt(7);
  with Value do
    SetGeneric<Byte>(10);
  if Value.Number <> 11 then
    Halt(8);
  with Value do
    SetPlain(30);
  if Value.Number <> 30 then
    Halt(9);

  Outer := TOuter.Create;
  try
    Outer.Invoke;
  finally
    Outer.Free;
  end;
  if ExplicitGenericMatches <> 1 then
    Halt(1);
  if WithVariableMatches <> 1 then
    Halt(2);
  if WithExpressionMatches <> 1 then
    Halt(3);
  if PlainWithMatches <> 1 then
    Halt(4);
  if WrongMatches <> 0 then
    Halt(5);
  if DestroyedTargets <> 2 then
    Halt(6);
end.
