{ %FAIL }

program fam_funcref_result_rejected_01;

{ a function reference cannot return a FAM-record by value }

{$mode unleashed}

type
  TFam = record
    code: integer;
    data: array[] of byte;
  end;

  TMake = reference to function: TFam;

begin
end.
