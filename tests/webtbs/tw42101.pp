{ %OPT=-Fauw42101 }

{ a -Fa unit that has no ppu yet is compiled along with the program; the
  scheduler used to hit an internal error on it }

program tw42101;

begin
  if not loaded then
    halt(1);
end.
