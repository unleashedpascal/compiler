{ %FAIL }

program fam_embed_tail_byval_rejected_01;

{ a record ending in an embedded FAM-record cannot be passed by value }

{$mode unleashed}

type
  TInner = record
    code: integer;
    data: array[] of byte;
  end;

  TOuter = record
    id: integer;
    embed TInner;
  end;

procedure consume(o: TOuter);
begin
end;

begin
end.
