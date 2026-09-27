library lstaticlib_lib_thread_08;

{$mode unleashed}

uses {$ifdef UNIX}cthreads, {$endif}SysUtils;

var
  ticks: longint;

function tick(p: pointer): ptrint;
begin
  for var i := 1 to 3 do InterlockedIncrement(ticks);
  result := 0;
end;

// a thread the library starts itself, joined before the export returns
function libThreadTicks: longint; cdecl;
begin
  ticks := 0;
  var id := BeginThread(@tick, nil);
  WaitForThreadTerminate(id, 0);
  CloseThread(id);
  result := ticks;
end;

exports
  rtlInit        name 'libthread_init',
  rtlDone        name 'libthread_done',
  libThreadTicks name 'libthread_ticks';

begin
end.
