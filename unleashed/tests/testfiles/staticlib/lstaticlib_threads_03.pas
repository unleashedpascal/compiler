library lstaticlib_threads_03;

{$mode unleashed}

uses {$ifdef UNIX}cthreads, {$endif}SysUtils;

threadvar
  calls: longint;

// per-thread counter plus some heap traffic, called from threads the host
// created: the export wrapper has to set the thread up on its first call
function threadsCount: longint; cdecl;
begin
  inc(calls);
  var s := IntToStr(calls);
  result := calls+Length(s)-Length(s);
end;

exports
  rtlInit name 'threads_init',
  rtlDone name 'threads_done',
  threadsCount name 'threads_count';

begin
end.
