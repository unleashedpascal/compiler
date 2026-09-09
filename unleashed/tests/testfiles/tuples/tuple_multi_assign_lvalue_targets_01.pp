program tuple_multi_assign_lvalue_targets_01;

{$mode unleashed}

type
  TPair = record
    p, q: integer;
  end;

  PPair = ^TPair;

  TBox = class
    lo, hi: integer;
  end;

var
  st: array[0..1] of integer = (1, 2);
  rec: TPair = (p: 1; q: 2);

function pair: (integer, integer);
begin
  result := (7, 8);
end;

procedure swapOpen(arr: array of integer);
begin
  (arr[0], arr[1]) := (arr[1], arr[0]);
  if (arr[0] <> 20) or (arr[1] <> 10) then halt(3);
end;

begin
  (st[0], st[1]) := (st[1], st[0]);
  if (st[0] <> 2) or (st[1] <> 1) then halt(1);

  (rec.p, rec.q) := (rec.q, rec.p);
  if (rec.p <> 2) or (rec.q <> 1) then halt(2);

  var dyn: array of integer := [10, 20];
  swapOpen(dyn);
  (dyn[0], dyn[1]) := (dyn[1], dyn[0]);
  if (dyn[0] <> 20) or (dyn[1] <> 10) then halt(4);

  var ptr: PPair := @rec;
  (ptr^.p, ptr^.q) := (ptr^.q, ptr^.p);
  if (rec.p <> 1) or (rec.q <> 2) then halt(5);

  var box := TBox.Create;
  (box.lo, box.hi) := pair;
  if (box.lo <> 7) or (box.hi <> 8) then halt(6);
  box.Free;

  // index expression evaluated once per target, after the tuple is built
  var i := 0;
  (st[i], _) := (st[i + 1], 99);
  if (st[0] <> 1) or (st[1] <> 1) then halt(7);

  var recs: array[0..1] of TPair;
  recs[0].p := 3; recs[1].q := 4;
  (recs[0].p, recs[1].q) := (recs[1].q, recs[0].p);
  if (recs[0].p <> 4) or (recs[1].q <> 3) then halt(8);

  writeln('ok');
end.
