{ %NORUN %OPT=-XA }
program staticlib_program_exports_07;

{$mode unleashed}

// a program builds into a static library as well, exports included; the
// export gets its thread-entry wrapper since it carries no public name
function seven: longint; cdecl;
begin
  result := 7;
end;

exports
  rtlInit name 'seven_init',
  rtlDone name 'seven_done',
  seven;

begin
end.
