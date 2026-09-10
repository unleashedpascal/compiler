{ %FAIL }

program fam_inline_record_not_last_rejected_01;

{ an inline anonymous record ending in a FAM must be the last member }

{$mode unleashed}

type
  TBad = record
    id: integer;
    record
      code: integer;
      data: array[] of byte;
    end;
    tail: integer;
  end;

begin
end.
