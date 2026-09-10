{ %FAIL }

program fam_static_var_rejected_02;

{ an inline `static` cannot infer a FAM-record type from a dereference }

{$mode unleashed}

type
  PFam = ^TFam;
  TFam = record
    code: integer;
    data: array[] of byte;
  end;

var
  p: PFam;

procedure foo;
begin
  static bad := p^;
  writeln(bad.code);
end;

begin
  GetMem(p, SizeOf(TFam) + 4);
  foo;
end.
