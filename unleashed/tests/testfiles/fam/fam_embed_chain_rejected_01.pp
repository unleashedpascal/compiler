{ %FAIL }

program fam_embed_chain_rejected_01;

{ a record ending in an embedded FAM-record is a FAM-record itself and
  cannot be a plain field of a third record }

{$mode unleashed}

type
  TInner = record
    code: integer;
    data: array[] of byte;
  end;

  TMiddle = record
    id: integer;
    embed TInner;
  end;

  TBad = record
    middle: TMiddle;
  end;

begin
end.
