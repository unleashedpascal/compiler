{ %FAIL }

program fam_threadstatic_var_rejected_01;

{ a `threadstatic` variable of FAM-record type is rejected like a threadvar }

{$mode unleashed}

type
  TFam = record
    code: integer;
    data: array[] of byte;
  end;

procedure foo;
begin
  threadstatic bad: TFam;
  bad.code := 1;
end;

begin
  foo;
end.
