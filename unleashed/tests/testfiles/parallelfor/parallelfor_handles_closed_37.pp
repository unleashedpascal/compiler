{ %OS=win32,win64 }
program parallelfor_handles_closed_37;
{$mode unleashed}
// the barrier closes every worker handle it joined: the process handle
// count stays flat across many loops. windows only, where BeginThread
// hands back a kernel handle that must be closed explicitly
uses Windows;

function GetProcessHandleCount(process: THandle; var count: DWord): BOOL; stdcall; external 'kernel32.dll';

function handleCount: DWord;
begin
  result := 0;
  GetProcessHandleCount(GetCurrentProcess, result);
end;

var sink: array[100] of Integer;

begin
  for parallel var i := 0 to 99 do sink[i] := i;
  var before := handleCount;
  for var n := 1 to 200 do
    for parallel var i := 0 to 99 do sink[i] := i*n;
  var after := handleCount;
  if after > before + 8 then halt(1);
end.
