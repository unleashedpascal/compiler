{ %FAIL %OPT=-XA }
library staticlib_no_exports_06;

{$mode unleashed}

// nothing exported: nothing would survive the gc, the compiler refuses
function hidden: longint; cdecl;
begin
  result := 1;
end;

begin
end.
