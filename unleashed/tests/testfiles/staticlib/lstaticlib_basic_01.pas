library lstaticlib_basic_01;

{$mode unleashed}

uses SysUtils, Classes;

threadvar
  calls: longint;

var
  bodyTrace: string = '';

// classes, strings, a threadvar: the runtime has to be up for any of it
function basicCrack(n: longint): longint; cdecl;
begin
  inc(calls);
  var list := autofree TStringList.Create;
  for var i := 1 to n do list.Add(IntToStr(i*i));
  result := list.Count+calls+Length(list.CommaText);
end;

// an exception raised and caught inside the library
function basicBoom(n: longint): longint; cdecl;
begin
  result := -1;
  try
    if n > 0 then raise Exception.CreateFmt('boom %d', [n]);
  except
    on e: Exception do result := Length(e.Message);
  end;
end;

// the library body runs from rtlInit
function basicBodyRan: longint; cdecl;
begin
  result := Length(bodyTrace);
end;

exports
  rtlInit name 'basic_init',
  rtlDone name 'basic_done',
  basicCrack name 'basic_crack',
  basicBoom name 'basic_boom',
  basicBodyRan name 'basic_body_ran';

begin
  bodyTrace := 'body';
end.
