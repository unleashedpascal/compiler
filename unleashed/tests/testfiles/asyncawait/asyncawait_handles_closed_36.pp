{ %OS=win32,win64 }
program asyncawait_handles_closed_36;
{$mode unleashed}
// a future releases its worker handle and event when the last reference
// drops, awaited or not: the process handle count stays flat. windows
// only, where BeginThread and RTLEventCreate hand back kernel handles
uses Windows;

function GetProcessHandleCount(process: THandle; var count: DWord): BOOL; stdcall; external 'kernel32.dll';

function handleCount: DWord;
begin
  result := 0;
  GetProcessHandleCount(GetCurrentProcess, result);
end;

function work(x: Integer): Integer;
begin
  result := x * 2;
end;

begin
  var f0 := async work(1);
  await f0;
  var before := handleCount;
  var acc := 0;
  for var n := 1 to 200 do
  begin
    var f := async work(n);
    acc += await f;
  end;
  if acc <> 40200 then halt(1);
  for var n := 1 to 200 do
    async work(n);
  Sleep(300);
  var after := handleCount;
  if after > before + 8 then halt(2);
end.
