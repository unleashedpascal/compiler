program tuple_named_first_field_type_name_01;

{$mode unleashed}

type
  TNum = integer;

// a field named like a type (`text` is the file type) still makes a named tuple
function a: (text: string; n: integer);
begin
  result := ('x', 1);
end;

function b: (n: integer; text: string);
begin
  result := (2, 'y');
end;

// several names before the colon, the first one shadowing a type
function c: (text, name: string; n: integer);
begin
  result := ('p', 'q', 3);
end;

// the same identifier as the first POSITIONAL element stays a type
function d: (TNum, string);
begin
  result := (4, 'z');
end;

var
  v: (TNum: integer; s: string);

begin
  if (a.text <> 'x') or (a.n <> 1) then halt(1);
  if (b.n <> 2) or (b.text <> 'y') then halt(2);
  if (c.text <> 'p') or (c.name <> 'q') or (c.n <> 3) then halt(3);
  if (d[0] <> 4) or (d[1] <> 'z') then halt(4);
  v := (5, 'w');
  if (v.TNum <> 5) or (v.s <> 'w') then halt(5);
  writeln('ok');
end.
