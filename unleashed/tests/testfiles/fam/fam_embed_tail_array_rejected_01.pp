{ %FAIL }

program fam_embed_tail_array_rejected_01;

{ a record ending in an embedded FAM-record cannot be an array element }

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

  TBad = array[0..1] of TOuter;

begin
end.
