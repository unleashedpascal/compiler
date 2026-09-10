{ %FAIL }

program fam_static_var_rejected_01;

{ a `static` section variable of FAM-record type has no room for a tail }

{$mode unleashed}

type
  TFam = record
    code: integer;
    data: array[] of byte;
  end;

procedure foo;
static
  bad: TFam;
begin
  bad.code := 1;
end;

begin
  foo;
end.
