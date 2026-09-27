{ %PRELIB=lstaticlib_basic_01.pas }
program staticlib_basic_01;

{$mode unleashed}
{$linklib lstaticlib_basic_01}

procedure basicInit; cdecl; external name 'basic_init';
procedure basicDone; cdecl; external name 'basic_done';
function basicCrack(n: longint): longint; cdecl; external name 'basic_crack';
function basicBoom(n: longint): longint; cdecl; external name 'basic_boom';
function basicBodyRan: longint; cdecl; external name 'basic_body_ran';

begin
  basicInit;
  // the library body ran as part of rtlInit
  if basicBodyRan <> 4 then halt(1);
  // 10 squares + 1 call + Length('1,4,9,16,25,36,49,64,81,100')
  if basicCrack(10) <> 38 then halt(2);
  // 3 squares + 2 calls + Length('1,4,9')
  if basicCrack(3) <> 10 then halt(3);
  // Length('boom 42')
  if basicBoom(42) <> 7 then halt(4);
  if basicBoom(0) <> -1 then halt(5);
  basicDone;
  writeln('ok');
end.
