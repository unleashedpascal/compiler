{ %PRELIB=lstaticlib_threads_03.pas }
program staticlib_threads_03;

{$mode unleashed}
{$linklib lstaticlib_threads_03}

uses {$ifdef UNIX}cthreads, {$endif}SysUtils;

procedure threadsInit; cdecl; external name 'threads_init';
procedure threadsDone; cdecl; external name 'threads_done';
function threadsCount: longint; cdecl; external name 'threads_count';

const
  WORKERS = 4;
  ROUNDS = 1000;

var
  last: array[0..WORKERS-1] of longint;

// threads the library never heard of: its threadvar has to be per thread
// and its heap has to survive concurrent callers
function worker(p: pointer): ptrint;
begin
  var slot := ptrint(p);
  for var i := 1 to ROUNDS do last[slot] := threadsCount;
  result := 0;
end;

begin
  threadsInit;
  var ids: array[0..WORKERS-1] of TThreadID;
  for var i := 0 to WORKERS-1 do ids[i] := BeginThread(@worker, pointer(ptrint(i)));
  for var i := 0 to WORKERS-1 do WaitForThreadTerminate(ids[i], 0);
  for var i := 0 to WORKERS-1 do if last[i] <> ROUNDS then halt(10+i);
  // the main thread has its own counter
  if threadsCount <> 1 then halt(20);
  threadsDone;
  writeln('ok');
end.
