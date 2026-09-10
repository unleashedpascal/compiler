{ %FAIL }

program fam_inline_var_rejected_03;

{ an inline variable cannot infer a bare flexible array type }

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
  var bad := p^.data;
end.
