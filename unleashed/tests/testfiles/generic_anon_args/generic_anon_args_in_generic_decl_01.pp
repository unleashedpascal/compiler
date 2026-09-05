program generic_anon_args_in_generic_decl_01;
{$mode unleashed}

// an anonymous argument that mentions the enclosing generic's own parameter
// is replayed with the concrete type on specialization

type
  TPack<T> = record
    items: TArray<(k: T; v: string)>;
    function count: integer;
  end;

function TPack<T>.count: integer;
begin
  result := length(items);
end;

var
  p: TPack<integer>;
  q: TPack<integer>;
  plain: TArray<(k: integer; v: string)>;

begin
  p.items := [(1, 'a'), (2, 'b')];
  q := p;
  if (q.count <> 2) or (q.items[1].k <> 2) or (q.items[1].v <> 'b') then halt(1);
  plain := q.items;
  if plain[0].v <> 'a' then halt(2);
end.
