program generic_anon_args_pointer_result_01;
{$mode unleashed}

// `^T` as an argument in a function result and in a type block, where the
// pointed type may still be declared later in the same block

type
  TLaterPtrs = TArray<^TLater>;
  TLater = record x: integer; end;

function make: TArray<^integer>;
begin
  setlength(result, 1);
  new(result[0]);
  result[0]^ := 5;
end;

function firstValue(const a: TArray<^integer>): integer;
begin
  result := a[0]^;
end;

var
  lp: TLaterPtrs;
  l: TLater;

begin
  var m := make;
  if firstValue(m) <> 5 then halt(1);
  dispose(m[0]);
  l.x := 8;
  lp := [@l];
  if lp[0]^.x <> 8 then halt(2);
end.
