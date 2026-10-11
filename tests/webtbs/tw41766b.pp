{ %fail }
{$mode objfpc}

{ Allowing readonly storage does not make scalar literals addressable. }
procedure Consume(constref Value);
begin
end;

begin
  Consume(UInt32(123));
end.
