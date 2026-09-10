program fam_embed_tail_01;

{ a record ending in an embedded FAM-record is a FAM-record: the FAM sits
  at the tail and the pointer allocation pattern works through it }

{$mode unleashed}

type
  TInner = record
    code: integer;
    data: array[] of byte;
  end;

  POuter = ^TOuter;
  TOuter = record
    id: integer;
    embed TInner;
  end;

var
  p: POuter;

begin
  if SizeOf(TOuter) <> 8 then halt(1);
  GetMem(p, SizeOf(TOuter) + 4);
  p^.id := 1;
  p^.code := 2;
  for var i := 0 to 3 do
    p^.data[i] := 10 + i;
  if p^.id <> 1 then halt(2);
  if p^.code <> 2 then halt(3);
  if p^.data[0] <> 10 then halt(4);
  if p^.data[3] <> 13 then halt(5);
  FreeMem(p);
end.
