{ %FAIL }

program fam_field_after_visibility_rejected_01;

{ a new visibility section does not reopen the record after a FAM }

{$mode unleashed}

type
  TBad = record
  public
    code: integer;
    data: array[] of byte;
  public
    tail: integer;
  end;

begin
end.
