program generic_anon_args_const_paren_objfpc_01;
{$mode objfpc}

// outside unleashed mode a parenthesized constant argument keeps working

type
  generic TBuf<const N: integer> = array[0..N-1] of byte;

var buf: specialize TBuf<(2+2)>;

begin
  if length(buf) <> 4 then halt(1);
end.
