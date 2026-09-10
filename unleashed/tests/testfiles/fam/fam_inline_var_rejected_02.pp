{ %FAIL }

program fam_inline_var_rejected_02;

{ an inline variable cannot infer a FAM-record type from a dereference }

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
  var bad := p^;
end.
