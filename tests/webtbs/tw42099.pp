{ %OPT=-O3 }

{ on i386 the peephole optimizer merged an add into a later load and moved
  the load up to the add, over an instruction that reuses the register the
  load writes to, so the loaded value was lost }

program tw42099;

{$mode objfpc}{$inline on}
{$r-}{$q-}

type
  ttable = class
    src: pbyte;
    count: sizeint;
    slots, pairs, links: array of longint;
    wrap, cur: sizeint;
    shift: longint;
    procedure insert_all(stop: sizeint);
  end;

function slot_of(p: pbyte; shift: longint): dword; inline;
begin
  result := dword(pdword(p)^ * dword(3141592653)) shr (32 - shift);
end;

function pair_of(p: pbyte): dword; inline;
begin
  result := dword((p[0] or (dword(p[1]) shl 8) or (dword(p[2]) shl 16)) * dword(1000033)) shr (32 - 12);
end;

procedure ttable.insert_all(stop: sizeint);
var
  s: dword;
begin
  if stop > count - 3 then
    stop := count - 3;
  while cur < stop do
    begin
      s := slot_of(src + cur, shift);
      links[cur and wrap] := slots[s];
      slots[s] := cur;
      pairs[pair_of(src + cur)] := cur;
      inc(cur);
    end;
end;

const
  input: array[0..15] of byte = (1, 2, 3, 4, 1, 2, 3, 4, 1, 2, 3, 4, 1, 2, 3, 4);
var
  t: ttable;
  i: longint;
begin
  t := ttable.create;
  t.src := @input[0];
  t.count := 16;
  t.shift := 10;
  t.wrap := 63;
  setlength(t.slots, 1 shl 10);
  setlength(t.pairs, 1 shl 12);
  setlength(t.links, 64);
  for i := 0 to high(t.slots) do
    t.slots[i] := -1;
  t.insert_all(12);
  { the input repeats every 4 bytes: position i links back to i-4 }
  if t.slots[slot_of(@input[0], 10)] <> 8 then
    halt(1);
  for i := 0 to 3 do
    if t.links[i] <> -1 then
      halt(2);
  for i := 4 to 11 do
    if t.links[i] <> i - 4 then
      halt(3);
  t.free;
end.
