program staticlib_entrypoint_04;

{$mode unleashed}
{$entrypoint main}

uses SysUtils, Classes;

threadvar
  hits: longint;

// nothing ran before main: rtlInit brings the runtime up, rtlDone takes it
// down when work returns, halt ends the process without a startup frame
procedure work;
begin
  rtlInit;
  defer rtlDone;
  inc(hits);
  var list := autofree TStringList.Create;
  list.Add('a');
  try
    raise Exception.Create('boom');
  except
    on e: Exception do if e.Message <> 'boom' then halt(2);
  end;
  if (list.Count <> 1) or (hits <> 1) then halt(3);
  writeln('ok');
end;

procedure main;
begin
  work;
  halt(0);
end;

begin
end.
