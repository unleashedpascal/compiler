program static_section_zero_init_read_no_warning_01;

{ %OPT=-Sew }

{$mode unleashed}

// reading a static before any write is fine: data segment storage is zero-filled

function memoized(n: integer): integer;
static
  memo: array[1..8] of integer;
  calls: integer;
begin
  if memo[n] = 0 then memo[n] := n * n;
  calls += 1;
  result := memo[n];
end;

function firstSeen(s: string): boolean;
static
  last: string;
begin
  result := last <> s;
  last := s;
end;

begin
  if memoized(3) <> 9 then halt(1);
  if memoized(3) <> 9 then halt(2);
  if not firstSeen('a') then halt(3);
  if firstSeen('a') then halt(4);
  writeln('ok');
end.
