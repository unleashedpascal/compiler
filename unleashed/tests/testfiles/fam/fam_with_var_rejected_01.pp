{ %FAIL }

program fam_with_var_rejected_01;

{ a with-scoped inline variable of FAM-record type is a stack variable too }

{$mode unleashed}

type
  PFam = ^TFam;
  TFam = record
    code: integer;
    data: array[] of byte;
  end;

var
  p: PFam;
begin
  GetMem(p, SizeOf(TFam) + 4);
  with var bad := p^ do
    writeln(bad.code);
end.
