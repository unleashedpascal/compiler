program lock_in_except_handler_01;

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

constructor TCounter.Create;
begin
  InitCriticalSection(cs);
end;

destructor TCounter.Destroy;
begin
  DoneCriticalSection(cs);
  inherited;
end;

// a lock on a field is the whole statement of an exception handler
procedure TCounter.run;
begin
  while count < 3 do try
    inc(count);
    if count = 2 then raise Exception.Create('two');
  except
    on e: Exception do lock(cs) do begin
      if e.Message <> 'two' then halt(1);
      inc(count, 10);
    end;
  end;
end;

begin
  var counter := TCounter.Create;
  counter.run;
  if counter.count <> 12 then halt(2);
  // the section must be free again
  if TryEnterCriticalSection(counter.cs) = 0 then halt(3);
  LeaveCriticalSection(counter.cs);
  counter.Free;
end.
