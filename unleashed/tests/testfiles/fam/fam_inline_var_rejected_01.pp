{ %FAIL }

program fam_inline_var_rejected_01;

{ an inline variable of FAM-record type cannot live on the stack }

{$mode unleashed}

type
  TFam = record
    code: integer;
    data: array[] of byte;
  end;

begin
  var bad: TFam;
end.
