{ %OPT=-Sew }
program tuple_destructure_marks_targets_written_01;

{$mode unleashed}

// a destructuring assignment counts as a write to its targets, so a later
// read does not warn about an uninitialized variable (fatal under -Sew)

type
  TRec = record
    a, b: integer;
  end;

var
  arr: array[2] of integer;
  rec: TRec;
  x, y: integer;

procedure locals;
begin
  var s: string;
  var n: integer;
  (s, n) := ('seven', 7);
  if (s <> 'seven') or (n <> 7) then halt(4);
end;

begin
  (arr[0], arr[1]) := (1, 2);
  if arr[0]+arr[1] <> 3 then halt(1);

  (rec.a, rec.b) := (3, 4);
  if rec.a+rec.b <> 7 then halt(2);

  (x, y) := (5, 6);
  if x+y <> 11 then halt(3);

  locals;
  writeln('ok');
end.
