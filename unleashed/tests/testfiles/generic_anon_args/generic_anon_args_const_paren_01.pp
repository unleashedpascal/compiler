program generic_anon_args_const_paren_01;
{$mode unleashed}

// a parenthesized constant argument is still a constant, not a tuple

type
  TBuf<const N: integer> = array[0..N-1] of byte;

var buf: TBuf<(2+2)>;

begin
  if length(buf) <> 4 then halt(1);
end.
