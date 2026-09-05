program generic_anon_args_nested_01;
{$mode unleashed}

// anonymous arguments nest, and work as a record field, a type alias, a
// function result and an inline variable

type
  TGrid = TArray<array of (a: integer; b: string)>;

  TRec = record
    items: TArray<(a: integer; b: string)>;
    grid: TGrid;
  end;

function build: TArray<(a: integer; b: string)>;
begin
  result := [(7, 'seven')];
end;

function firstNames(const m: TArray<TArray<(integer, string)>>): string;
begin
  result := m[0][0]._2 + m[1][0]._2;
end;

var r: TRec;

begin
  r.items := build;
  if r.items[0].b <> 'seven' then halt(1);
  r.grid := [[(1, 'x')], [(2, 'y'), (3, 'z')]];
  if r.grid[1][1].b <> 'z' then halt(2);
  var m: TArray<TArray<(integer, string)>> := [[(1, 'p')], [(2, 'q')]];
  if firstNames(m) <> 'pq' then halt(3);
  var g: TArray<array of (a: integer; b: string)> := r.grid;
  if g[0][0].a <> 1 then halt(4);
end.
