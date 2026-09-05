{ %PRELIB=lstaticlib_basic_01.pas }
program staticlib_cycles_02;

{$mode unleashed}
{$linklib lstaticlib_basic_01}

procedure basicInit; cdecl; external name 'basic_init';
procedure basicDone; cdecl; external name 'basic_done';
function basicCrack(n: longint): longint; cdecl; external name 'basic_crack';
function basicBoom(n: longint): longint; cdecl; external name 'basic_boom';
function basicBodyRan: longint; cdecl; external name 'basic_body_ran';

begin
  // the runtime comes up and goes down again on every cycle
  for var cycle := 1 to 5 do begin
    basicInit;
    if basicBodyRan <> 4 then halt(cycle*10+1);
    if basicCrack(3) < 8 then halt(cycle*10+2);
    if basicBoom(42) <> 7 then halt(cycle*10+3);
    basicDone;
  end;
  // nested init/done pairs: only the outermost pair does the work
  basicInit;
  basicInit;
  if basicBoom(1) <> 6 then halt(61);
  basicDone;
  if basicBoom(1) <> 6 then halt(62);
  basicDone;
  writeln('ok');
end.
