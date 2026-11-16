{ %OPT=-O2 }
{$mode objfpc}

{ Untyped constref: storage identity, materialization and forwarding are
  different paths. Check the cross-product of value origin and consumer,
  including types returned in integer/FP registers and managed temporaries. }

var
  Calls: LongInt;

function Read32(constref Value): UInt32;
var
  V: UInt32 absolute Value;
begin
  Result := V;
end;

function Forward32(constref Value): UInt32;
begin
  Result := Read32(Value);
end;

function TypedForward32(constref Value: UInt32): UInt32;
begin
  Result := Forward32(Value);
end;

function AddressOf(constref Value): Pointer;
begin
  Result := @Value;
end;

function ForwardAddress(constref Value): Pointer;
begin
  Result := AddressOf(Value);
end;

function Make32(Value: UInt32): UInt32;
begin
  Inc(Calls);
  Result := Value;
end;

function CheckPair(constref A, B; ExpectedA, ExpectedB: UInt32): Boolean;
begin
  Result := (Read32(A) = ExpectedA) and (Read32(B) = ExpectedB) and (@A <> @B);
end;

function Read64(constref Value): Int64;
var
  V: Int64 absolute Value;
begin
  Result := V;
end;

function Make64(Value: Int64): Int64;
begin
  Inc(Calls);
  Result := Value;
end;

function ReadFloat(constref Value): Double;
var
  V: Double absolute Value;
begin
  Result := V;
end;

function MakeFloat(Value: Double): Double;
begin
  Inc(Calls);
  Result := Value;
end;

function ReadString(constref Value): AnsiString;
var
  V: AnsiString absolute Value;
begin
  Result := V;
end;

function MakeString: AnsiString;
begin
  Inc(Calls);
  SetLength(Result, 3);
  Result[1] := 'a';
  Result[2] := 'b';
  Result[3] := 'c';
end;

const
  Value32: UInt32 = $87654321;
var
  I: LongInt;
  Local: UInt32;
  Values: array of UInt32;
  Rec: record
    Value: UInt32;
  end;
begin
  Local := Value32;
  Rec.Value := Value32;
  SetLength(Values, 2);
  Values[1] := Value32;

  { A real lvalue must not turn into a copy, even after forwarding. }
  if AddressOf(Local) <> @Local then Halt(1);
  if ForwardAddress(Rec.Value) <> @Rec.Value then Halt(2);
  if ForwardAddress(Values[1]) <> @Values[1] then Halt(3);
  if Forward32(Value32) <> Value32 then Halt(4);
  if TypedForward32(Local) <> Value32 then Halt(5);

  for I := 0 to 7 do
    begin
      Calls := 0;
      if Read32(Make32(Value32 + UInt32(I))) <> Value32 + UInt32(I) then Halt(6);
      if Calls <> 1 then Halt(7);
      Calls := 0;
      if Forward32(Make32(UInt32(I) + UInt32(10))) <> UInt32(I + 10) then Halt(8);
      if Calls <> 1 then Halt(9);
      Calls := 0;
      if TypedForward32(Make32(UInt32(I))) <> UInt32(I) then Halt(10);
      if Calls <> 1 then Halt(11);
      Calls := 0;
      if not CheckPair(Make32(UInt32(I)), Make32(UInt32(I + 1)), I, I + 1) then Halt(16);
      if Calls <> 2 then Halt(17);
    end;

  { A typed const already has storage; a call result may need a temporary. }
  Calls := 0;
  if Read64(Make64(-$123456789AB)) <> -$123456789AB then Halt(12);
  if ReadFloat(MakeFloat(1.25)) <> 1.25 then Halt(13);
  if ReadString(MakeString) <> 'abc' then Halt(14);
  if Calls <> 3 then Halt(15);
  writeln('ok');
end.
