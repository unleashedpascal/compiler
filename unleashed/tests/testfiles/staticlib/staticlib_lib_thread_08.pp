{ %PRELIB=lstaticlib_lib_thread_08.pas }
program staticlib_lib_thread_08;

{$mode unleashed}
{$linklib lstaticlib_lib_thread_08}
// the archive cannot carry the shared libraries its cthreads needs
{$ifdef UNIX}{$linklib c}{$linklib pthread}{$linklib dl}{$endif}

procedure libThreadInit; cdecl; external name 'libthread_init';
procedure libThreadDone; cdecl; external name 'libthread_done';
function libThreadTicks: longint; cdecl; external name 'libthread_ticks';

begin
  // every cycle initializes the units of the library and its thread driver again
  for var cycle := 1 to 3 do begin
    libThreadInit;
    if libThreadTicks <> 3 then halt(cycle);
    libThreadDone;
  end;
  writeln('ok');
end.
