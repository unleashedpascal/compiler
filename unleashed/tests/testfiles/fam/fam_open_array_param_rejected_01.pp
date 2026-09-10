{ %FAIL }

program fam_open_array_param_rejected_01;

{ a FAM-record cannot be the element type of an open array parameter }

{$mode unleashed}

type
  TFam = record
    code: integer;
    data: array[] of byte;
  end;

procedure consume(const items: array of TFam);
begin
end;

begin
end.
