program tw41564;

{$mode delphi}

type
  TBase = record
    Value: Integer;
  end;
  TAlias = TBase;
  TFirst = type TBase;
  TSecond = type TBase;

  TBaseHelper = record helper for TBase
    function Marker: Integer;
    class function StaticMarker: Integer; static;
  end;

  TFirstHelper = record helper for TFirst
    function Marker: Integer;
    class function StaticMarker: Integer; static;
  end;

  TSecondHelper = record helper for TSecond
    function Marker: Integer;
    class function StaticMarker: Integer; static;
  end;

function TBaseHelper.Marker: Integer;
begin
  Result := 10;
end;

class function TBaseHelper.StaticMarker: Integer;
begin
  Result := 20;
end;

function TFirstHelper.Marker: Integer;
begin
  Result := 11;
end;

class function TFirstHelper.StaticMarker: Integer;
begin
  Result := 21;
end;

function TSecondHelper.Marker: Integer;
begin
  Result := 12;
end;

class function TSecondHelper.StaticMarker: Integer;
begin
  Result := 22;
end;

var
  Base: TBase;
  AliasValue: TAlias;
  First: TFirst;
  Second: TSecond;
begin
  if Base.Marker <> 10 then
    Halt(1);
  if AliasValue.Marker <> 10 then
    Halt(2);
  if First.Marker <> 11 then
    Halt(3);
  if Second.Marker <> 12 then
    Halt(4);
  if TBase.StaticMarker <> 20 then
    Halt(5);
  if TAlias.StaticMarker <> 20 then
    Halt(6);
  if TFirst.StaticMarker <> 21 then
    Halt(7);
  if TSecond.StaticMarker <> 22 then
    Halt(8);
end.
