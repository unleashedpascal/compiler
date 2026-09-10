{ %FAIL }

program fam_embed_tail_stack_var_rejected_01;

{ a record ending in an embedded FAM-record cannot live on the stack }

{$mode unleashed}

type
  TInner = record
    code: integer;
    data: array[] of byte;
  end;

  TOuter = record
    id: integer;
    embed TInner;
  end;

var
  bad: TOuter;
begin
end.
