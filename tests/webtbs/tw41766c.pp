{ %fail }
{$mode objfpc}

{ Readonly storage can be forwarded as constref, never as writable var/out. }
procedure Mutate(var Value);
begin
end;

procedure Clear(out Value);
begin
end;

procedure Forward(constref Value: UInt32);
begin
  Mutate(Value);
  Clear(Value);
end;

begin
end.
