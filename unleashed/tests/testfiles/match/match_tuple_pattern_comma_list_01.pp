program match_tuple_pattern_comma_list_01;

{$mode unleashed}

function closes(open, close: char): boolean;
begin
  result := match (open, close) of
    ('(', ')'), ('[', ']'), ('{', '}'): true;
    _: false;
  end;
end;

function quadrant(x, y: integer): integer;
begin
  match (x, y) of
    (0, 0): exit(0);
    (0, _), (_, 0): exit(-1);
  end;
  result := match (x > 0, y > 0) of
    (true, true): 1;
    (false, true): 2;
    (false, false), (true, false), _: 3;
  end;
end;

function classify(p: (integer, integer)): string;
begin
  result := match p of
    (1, 1), (2, 2), _: 'listed or other';
  end;
end;

var hits: integer;

begin
  if not closes('(', ')') then halt(1);
  if not closes('{', '}') then halt(2);
  if closes('(', ']') then halt(3);

  if quadrant(0, 0) <> 0 then halt(4);
  if quadrant(5, 0) <> -1 then halt(5);
  if quadrant(3, 4) <> 1 then halt(6);
  if quadrant(-3, 4) <> 2 then halt(7);
  if quadrant(3, -4) <> 3 then halt(8);
  if quadrant(-3, -4) <> 3 then halt(9);

  // trailing _ after tuple patterns turns the branch into a catch-all
  if classify((7, 8)) <> 'listed or other' then halt(10);

  // match all: an OR'd tuple branch is still one branch
  hits := 0;
  match all (1, 2) of
    (1, _), (_, 2): hits += 1;
    (9, 9), (1, 2): hits += 10;
    (0, 0): hits += 100;
  end;
  if hits <> 11 then halt(11);

  writeln('ok');
end.
