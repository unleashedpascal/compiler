{ %FAIL }

program fam_embed_in_union_rejected_01;

{ a FAM-record cannot be embedded into a union variant }

{$mode unleashed}

type
  TInner = record
    code: integer;
    data: array[] of byte;
  end;

  TBad = record
    id: integer;
    union
      embed TInner;
      raw: qword;
    end;
  end;

begin
end.
