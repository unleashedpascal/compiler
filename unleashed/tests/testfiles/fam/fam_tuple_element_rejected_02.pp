{ %FAIL }

program fam_tuple_element_rejected_02;

{ a tuple literal cannot carry a dereferenced FAM-record, so destructuring
  cannot smuggle one into a stack variable }

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
  var (n, bad) := (1, p^);
  writeln(n);
end.
