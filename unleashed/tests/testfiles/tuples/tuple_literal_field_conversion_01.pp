program tuple_literal_field_conversion_01;

{$mode unleashed}

type
  TQuote = (sym: string; lo: double);

procedure show(q: (string, double));
begin
  if (q[0] <> 'B') or (q[1] <> 2.5) then halt(20);
end;

function make: TQuote;
begin
  // a literal typed (string, single) converts into the declared (string, double)
  result := ('M', 7.5);
end;

begin
  // array literal elements convert to the declared element type
  var quotes: array of TQuote;
  quotes += [('A', 1.5)];
  quotes += [('B', 2.5), ('C', 3.5)];
  if length(quotes) <> 3 then halt(1);
  if (quotes[0].sym <> 'A') or (quotes[0].lo <> 1.5) then halt(2);
  if (quotes[2].sym <> 'C') or (quotes[2].lo <> 3.5) then halt(3);

  quotes := [('D', 4.5)];
  if (length(quotes) <> 1) or (quotes[0].lo <> 4.5) then halt(4);

  // a tuple variable with a narrower field converts the same way
  var v := ('E', 5.5);
  quotes += [v];
  if (quotes[1].sym <> 'E') or (quotes[1].lo <> 5.5) then halt(5);

  // integer literals land in longint; wider and narrower targets both work
  var wide: array of (name: string; n: int64);
  wide += [('F', 6)];
  if wide[0].n <> 6 then halt(6);
  var narrow: array of (name: string; n: byte);
  narrow += [('G', 7)];
  if narrow[0].n <> 7 then halt(7);

  // shortstring field from a string literal
  var shorts: array of (s: shortstring; n: integer);
  shorts += [('hello', 8)];
  if (shorts[0].s <> 'hello') or (shorts[0].n <> 8) then halt(8);

  // only a bare char literal becomes a string; a cast or a char variable stays char
  var ch := 'k';
  var chars: array of (c: char; s: shortstring);
  chars += [(Char('h'), 'hello'), (ch[1], 'kilo')];
  if (chars[0].c <> 'h') or (chars[1].c <> 'k') or (chars[1].s <> 'kilo') then halt(11);

  // parameter passing and function results go through the same conversion
  show(('B', 2.5));
  var m := make;
  if (m.sym <> 'M') or (m.lo <> 7.5) then halt(9);

  // element assignment
  SetLength(quotes, 1);
  quotes[0] := v;
  if quotes[0].lo <> 5.5 then halt(10);

  writeln('ok');
end.
