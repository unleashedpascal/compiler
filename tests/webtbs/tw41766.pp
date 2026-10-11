{$mode objfpc}

function FirstDWord(constref Value): UInt32;
var
  DWordValue: UInt32 absolute Value;
begin
  Result := DWordValue;
end;

function FirstByteAsDWord(constref Values): UInt32;
var
  Bytes: array[Byte] of Byte absolute Values;
begin
  Result := FirstDWord(Bytes[0]);
end;

var
  Data: array[Byte] of Byte;
  Expected: UInt32;

begin
  Expected := $12345678;
  Move(Expected, Data, SizeOf(Expected));
  if FirstByteAsDWord(Data) <> Expected then
    Halt(1);
  writeln('ok');
end.
