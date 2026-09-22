program tw41451;

{$mode delphi}

var
  InitializeCount: Integer;

type
  TManaged = record
    State: Word;
    class operator Initialize(var Value: TManaged);
    class operator Finalize(var Value: TManaged);
  end;

class operator TManaged.Initialize(var Value: TManaged);
begin
  Inc(InitializeCount);
  Value.State := $4145;
end;

class operator TManaged.Finalize(var Value: TManaged);
begin
end;

var
  One: TManaged;
  Many: array[1..6] of TManaged;
  I: Integer;
begin
  if InitializeCount <> 7 then
    Halt(1);
  if One.State <> $4145 then
    Halt(2);
  for I := Low(Many) to High(Many) do
    if Many[I].State <> $4145 then
      Halt(3);
end.
