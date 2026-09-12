program match_subject_evaluated_once_01;

{$mode unleashed}

// the subject of `match X of` is evaluated once, no matter how many
// branch comparisons follow (values, ranges, tuple fields, `match all`,
// expression form)

var
  calls: integer = 0;

function bump: integer;
begin
  inc(calls);
  result := 0;
end;

function bumpPair: (a: integer; b: integer);
begin
  inc(calls);
  result := (a: 2, b: 3);
end;

function bumpStr: ansistring;
begin
  inc(calls);
  result := 'foo';
end;

begin
  var hit := 0;
  match bump of
    1: hit := 1;
    2: hit := 2;
    3: hit := 3;
    _: hit := 9;
  end;
  if hit <> 9 then halt(1);
  if calls <> 1 then halt(2);

  calls := 0;
  match bump of
    1..5: hit := 1;
    6..9, 10..20: hit := 2;
    _: hit := 9;
  end;
  if hit <> 9 then halt(3);
  if calls <> 1 then halt(4);

  calls := 0;
  match bumpPair of
    (1, _): hit := 1;
    (2, 4), (2, 5): hit := 2;
    (2, 3): hit := 3;
    _: hit := 9;
  end;
  if hit <> 3 then halt(5);
  if calls <> 1 then halt(6);

  calls := 0;
  hit := 0;
  match all bump of
    0: inc(hit);
    1: hit := 9;
    0: inc(hit);
  end;
  if hit <> 2 then halt(7);
  if calls <> 1 then halt(8);

  calls := 0;
  var v := match bump of
    1: 10;
    2: 20;
    _: 99;
  end;
  if v <> 99 then halt(9);
  if calls <> 1 then halt(10);

  calls := 0;
  var s := match bumpStr of
    'bar': 'B';
    'baz': 'Z';
    'foo': 'F';
    _: '?';
  end;
  if s <> 'F' then halt(11);
  if calls <> 1 then halt(12);

  // a fallthrough body changing the subject variable does not affect
  // later branches: they compare the value captured on entry
  var k := 1;
  hit := 0;
  match all k of
    1: begin inc(hit); k := 2; end;
    2: hit := 9;
  end;
  if hit <> 1 then halt(13);
end.
