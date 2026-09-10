{ %FAIL }

program fam_typed_const_rejected_01;

{ a typed constant of FAM-record type is static storage without a tail }

{$mode unleashed}

type
  TFam = record
    code: integer;
    data: array[] of byte;
  end;

const
  bad: TFam = (code: 1);

begin
end.
