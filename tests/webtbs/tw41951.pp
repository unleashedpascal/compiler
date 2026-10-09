{ catching an exception class declared in the same module from two
  routines used to trip IE 2016070102 on SEH targets: the main block is
  generated after the VMTs, so the second filter table saw the VMT
  symbol already defined while the first one had registered it as
  external }

program tw41951;

{$mode objfpc}

uses
  SysUtils;

type
  eown = class(Exception);

procedure p;
begin
  try
    raise eown.Create('x');
  except
    on eown do
      writeln('caught in p');
  end;
end;

begin
  try
    p;
    raise eown.Create('y');
  except
    on eown do
      writeln('caught in main');
  end;
end.
