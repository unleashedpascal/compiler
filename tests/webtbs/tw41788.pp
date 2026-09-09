program tw41788;

{$mode delphi}

type
  TEnumerator<T> = class
  protected
    function DoMoveNext: Boolean; virtual;
  end;

  TEnumerable = class
    class function List<T>: TEnumerator<T>; static;
  end;

  TConsumer<T> = class
    procedure Run;
  end;

var
  MoveCount: LongInt;
  ValueDigest: LongInt;

function TEnumerator<T>.DoMoveNext: Boolean;
begin
  Inc(MoveCount);
  ValueDigest := ValueDigest + 41788;
  Result := True;
end;

class function TEnumerable.List<T>: TEnumerator<T>;
begin
  Result := TEnumerator<T>.Create;
end;

procedure TConsumer<T>.Run;
var
  Enumerator: TEnumerator<T>;
begin
  Enumerator := TEnumerable.List<T>;
  try
    if not Enumerator.DoMoveNext then
      Halt(3);
  finally
    Enumerator.Free;
  end;
end;

var
  Consumer: TConsumer<LongInt>;
begin
  MoveCount := 0;
  ValueDigest := 0;
  Consumer := TConsumer<LongInt>.Create;
  try
    Consumer.Run;
  finally
    Consumer.Free;
  end;
  if MoveCount <> 1 then
    Halt(1);
  if ValueDigest <> 41788 then
    Halt(2);
end.
