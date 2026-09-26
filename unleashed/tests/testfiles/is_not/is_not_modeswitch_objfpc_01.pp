// `is not` and `not in` outside unleashed mode via the modeswitch alone

program is_not_modeswitch_objfpc_01;

{$mode objfpc}
{$modeswitch reorderedoperators}

type
  TBase = class end;
  TDerived = class(TBase) end;
  TFruit = (apple, banana, cherry);

var
  b, d: TBase;
  f: TFruit;

begin
  b := TBase.Create;
  d := TDerived.Create;

  if b is not TBase then halt(1);
  if d is not TBase then halt(2);
  if not (b is not TDerived) then halt(3);

  f := banana;
  if f not in [apple, cherry] then else halt(4);
  if f not in [banana] then halt(5);

  b.Free;
  d.Free;
end.
