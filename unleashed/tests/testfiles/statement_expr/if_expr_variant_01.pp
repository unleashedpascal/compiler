program if_expr_variant_01;

{$mode unleashed}

var
  v: variant;
begin
  // a variant in either branch makes the result a variant
  v := if 0 < 1 then 'foo' else Variant('bar');
  if v <> 'foo' then halt(1);
  v := if 0 < 1 then Variant('foo') else 'bar';
  if v <> 'foo' then halt(2);
  v := if 0 > 1 then 5 else Variant('bar');
  if v <> 'bar' then halt(3);
end.
