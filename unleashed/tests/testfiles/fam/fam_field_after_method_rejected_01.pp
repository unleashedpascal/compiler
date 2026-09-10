{ %FAIL }

program fam_field_after_method_rejected_01;

{ a method declaration does not reopen the record after a FAM }

{$mode unleashed}

type
  TBad = record
    code: integer;
    data: array[] of byte;
    procedure clear;
    var tail: integer;
  end;

procedure TBad.clear;
begin
end;

begin
end.
