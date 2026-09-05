{ %NORUN }
unit generic_anon_args_unit_01;
// support unit for generic_anon_args_cross_unit_01.pp: routines whose
// parameters are specializations on anonymous types, matched by shape from
// another module

{$mode unleashed}

interface

function sumPairs(const items: TArray<(a: integer; b: string)>): integer;
procedure fillPairs(out items: TArray<(a: integer; b: string)>);
procedure appendRow(var rows: TArray<array of string>);

implementation

function sumPairs(const items: TArray<(a: integer; b: string)>): integer;
begin
  result := 0;
  for var (n, s) in items do result += n + length(s);
end;

procedure fillPairs(out items: TArray<(a: integer; b: string)>);
begin
  items := [(5, 'five'), (6, 'six')];
end;

procedure appendRow(var rows: TArray<array of string>);
begin
  setlength(rows, length(rows) + 1);
  rows[high(rows)] := ['y', 'z'];
end;

end.
