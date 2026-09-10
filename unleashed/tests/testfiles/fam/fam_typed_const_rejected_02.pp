{ %FAIL }

program fam_typed_const_rejected_02;

{ an inline typed constant of FAM-record type is rejected like a global one }

{$mode unleashed}

type
  TFam = record
    code: integer;
    data: array[] of byte;
  end;

begin
  const bad: TFam = (code: 1);
end.
