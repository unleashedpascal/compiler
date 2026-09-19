program tuple_generic_alias_01;

{$mode unleashed}

// a generic type alias may be a tuple; the type parameters are the
// field types and every specialization is an ordinary tuple

type
  TPair<A, B> = (left: A; right: B);
  TPos<A, B> = (A, B);
  TTriple<T> = (T, T, T);

function pairUp<A, B>(const x: A; const y: B): TPair<A, B>;
begin
  result := (x, y);
end;

function posUp<A, B>(const x: A; const y: B): TPos<A, B>;
begin
  exit(x, y);
end;

function swap<A, B>(const p: TPair<A, B>): TPair<B, A>;
begin
  result := (p.right, p.left);
end;

function middle<T>(const tr: TTriple<T>): T;
begin
  result := tr._2;
end;

var
  p: TPair<integer, string>;
  q: TPos<string, double>;

begin
  p := pairUp<integer, string>(7, 'seven');
  if (p.left <> 7) or (p.right <> 'seven') then halt(1);

  var (n, s) := p;
  if (n <> 7) or (s <> 'seven') then halt(2);

  q := posUp<string, double>('pi', 3.5);
  if (q._1 <> 'pi') or (q._2 <> 3.5) then halt(3);

  var r := swap<integer, string>(p);
  if (r.left <> 'seven') or (r.right <> 7) then halt(4);

  // literal into a specialization, named and positional
  var t: TPair<integer, string> := (left: 1, right: 'one');
  if t <> (1, 'one') then halt(5);
  if t = p then halt(6);

  var tr: TTriple<string> := ('a', 'b', 'c');
  if middle<string>(tr) <> 'b' then halt(7);

  // the type parameters do not take up space in the record
  if sizeof(TPos<byte, byte>) <> 2 then halt(8);

  for var (a, b) in [p, t] do
    if a = 0 then halt(9);

  writeln(p);
  writeln(q._1, ' ', q._2:0:1);
  writeln(r);
end.
