{ %FAIL }

program fam_tuple_element_rejected_01;

{ a FAM-record cannot be a tuple element, the tuple stores it by value }

{$mode unleashed}

type
  TFam = record
    code: integer;
    data: array[] of byte;
  end;

var
  bad: (TFam, integer);

begin
end.
