{ %FAIL }

program fam_inline_record_nested_not_last_rejected_01;

{ a FAM two inline records deep still has to be the last member of the
  outermost record, also for an inline variable's anonymous type }

{$mode unleashed}

begin
  var q: record
    id: integer;
    record
      code: integer;
      record
        len: integer;
        data: array[] of byte;
      end;
    end;
    tail: integer;
  end := (id: 1; code: 2; len: 3; tail: 4);
end.
