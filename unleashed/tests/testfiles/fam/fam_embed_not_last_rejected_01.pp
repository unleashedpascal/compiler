{ %FAIL }

program fam_embed_not_last_rejected_01;

{ an embedded FAM-record brings its FAM along, so no field may follow it }

{$mode unleashed}

type
  TInner = record
    code: integer;
    data: array[] of byte;
  end;

  TBad = record
    id: integer;
    embed TInner;
    tail: integer;
  end;

begin
end.
