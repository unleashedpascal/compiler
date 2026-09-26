{ %OPT=-Sew }
program out_var_var_param_enum_nonzero_start_01;
{$mode unleashed}

// the hidden zero-init of `_` / `var k` at a var parameter of an enum or
// subrange whose range does not include 0 must not raise the constant
// range-check warning (an error under -Sew); the value is still 0
type
  TKind = (kdOne = 1, kdTwo);
  TPct = 50..100;

procedure pickKind(var k: TKind);
begin
  if longint(k) <> 0 then Halt(1);
  k := kdTwo;
end;

procedure pickPct(var p: TPct);
begin
  if longint(p) <> 0 then Halt(2);
  p := 75;
end;

begin
  pickKind(_);
  pickKind(var k);
  if k <> kdTwo then Halt(3);
  pickPct(_);
  pickPct(var p);
  if p <> 75 then Halt(4);
end.
