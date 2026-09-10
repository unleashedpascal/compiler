program fam_class_var_after_fam_01;

{ a class var after a FAM is static storage, not part of the layout }

{$mode unleashed}

type
  PMessage = ^TMessage;
  TMessage = record
    code: integer;
    data: array[] of byte;
    class var instances: integer;
  end;

var
  msg: PMessage;

begin
  if SizeOf(TMessage) <> 4 then halt(1);
  GetMem(msg, SizeOf(TMessage) + 4);
  msg^.code := 7;
  msg^.data[3] := 9;
  TMessage.instances := 1;
  if msg^.code <> 7 then halt(2);
  if msg^.data[3] <> 9 then halt(3);
  if TMessage.instances <> 1 then halt(4);
  FreeMem(msg);
end.
