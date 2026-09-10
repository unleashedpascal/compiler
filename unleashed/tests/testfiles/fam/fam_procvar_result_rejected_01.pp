{ %FAIL }

program fam_procvar_result_rejected_01;

{ a procedural type cannot return a FAM-record by value }

{$mode unleashed}

type
  TFam = record
    code: integer;
    data: array[] of byte;
  end;

  TMake = function: TFam;

begin
end.
