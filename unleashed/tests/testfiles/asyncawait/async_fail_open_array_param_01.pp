{ %FAIL %EXPECTMSG="`async` cannot pass an open array parameter on; pass a dynamic or static array" }
program async_fail_open_array_param_01;

{$mode unleashed}

function firstOf(const xs: array of integer): integer;
begin
  result := xs[0];
end;

function viaOpen(const ys: array of integer): integer;
begin
  var j := async firstOf(ys);
  result := await j;
end;

begin
  writeln(viaOpen([1, 2]));
end.
