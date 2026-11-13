{ %OPT=-O3 }

{ on i386 the peephole optimizer merged the add into the load that follows
  the store and moved the load up to the add, in front of the store, although
  the store writes the very byte the load reads }

program tw42100;

{$mode objfpc}

function store_then_load(base: pbyte; idx: sizeint; target: pbyte; value: byte): sizeint;
var
  p: pbyte;
begin
  p := base + idx;
  target^ := value;
  result := p^;
end;

var
  cells: array[0..3] of byte = (1, 2, 3, 4);
begin
  if store_then_load(@cells[0], 2, @cells[2], 50) <> 50 then
    halt(1);
end.
