program inline_vars_char_expression_stays_char_01;

{$mode unleashed}

var
  gch: char = 'x';

function firstOf(const t: string): char;
begin
  result := t[1];
end;

// overload resolution reports the inferred type without a compile-time constant
function isChar(c: char): boolean; overload;
begin
  result := true;
end;

function isChar(const s: string): boolean; overload;
begin
  result := false;
end;

procedure statics;
static
  sl := 'a';
  sc := Chr(66);
begin
  static ss := gch;
  if isChar(sl) then halt(20);
  if not isChar(sc) then halt(21);
  if not isChar(ss) then halt(22);
end;

begin
  var s := 'abc1';
  var i := 4;

  // char-typed expressions keep Char: only a char literal becomes a string
  var c1 := s[i];
  var c2 := gch;
  var c3 := firstOf(s);
  var c4 := Chr(64 + i);
  if not isChar(c1) then halt(1);
  if not isChar(c2) then halt(2);
  if not isChar(c3) then halt(3);
  if not isChar(c4) then halt(4);

  // set test, case and ord work on the inferred type
  if not (c1 in ['0'..'9']) then halt(5);
  case c2 of
    'x': ;
    else halt(6);
  end;
  if ord(c3) <> ord('a') then halt(7);

  var digits := 0;
  for var k := 1 to length(s) do
  begin
    var ch := s[k];
    if ch in ['0'..'9'] then digits += 1;
  end;
  if digits <> 1 then halt(8);

  // literals still infer the default string type
  var l1 := 'a';
  var l2 := #65;
  if isChar(l1) then halt(9);
  if isChar(l2) then halt(10);
  l1 := l1 + l2;
  if l1 <> 'aA' then halt(11);

  statics;
end.
