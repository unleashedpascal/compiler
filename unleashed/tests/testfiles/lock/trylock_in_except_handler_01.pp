program trylock_in_except_handler_01;

{$mode unleashed}

uses SysUtils;

type
  TCounter = class
    cs: TRTLCriticalSection;
    count: integer;
    constructor Create;
    destructor Destroy; override;
    procedure run;
  end;

var
  shared: integer;
  missed: integer;

constructor TCounter.Create;
begin
  InitCriticalSection(cs);
end;

destructor TCounter.Destroy;
begin
  DoneCriticalSection(cs);
  inherited;
end;

// each trylock form is the whole statement of an exception handler
procedure TCounter.run;
begin
  try
    raise Exception.Create('first');
  except
    on e: Exception do trylock(cs) wait 10 do inc(count) else inc(missed);
  end;
  try
    raise Exception.Create('second');
  except
    on e: Exception do trylock do inc(count) else inc(missed);
  end;
  try
    raise Exception.Create('third');
  except
    on e: Exception do trylock(shared) wait 10 do inc(shared) else inc(missed);
  end;
end;

begin
  var counter := TCounter.Create;
  counter.run;
  if counter.count <> 2 then halt(1);
  if shared <> 1 then halt(2);
  if missed <> 0 then halt(3);
  counter.Free;
end.
