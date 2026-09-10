{ %FAIL }

program fam_variant_part_after_fam_rejected_01;

{ a variant part cannot follow a FAM, it would overlay the tail }

{$mode unleashed}

type
  TBad = record
    code: integer;
    data: array[] of byte;
    case boolean of
      false: (tail: integer);
      true: (other: qword);
  end;

begin
end.
