{ %OPT=-O2 -OoCONSTPROP }

{ constant propagation into an if statement used to substitute the
  constant into both branches; when the condition folds to false, the
  dead branch may contain expressions only valid when the branch is
  entered, here an array access guarded by an in-range check, and the
  substitution caused a compile-time range check error }

program tb0730;

{$mode objfpc}{$H+}

type
  taction = (
    anone,
    aselect, apaste, ajump,
    { old values for config upgrade }
    aoldnone, aoldpaste, aoldjump
  );

const
  actionmap: array[aoldnone..aoldjump] of taction = (anone, apaste, ajump);

var
  fval: taction;

procedure setval(avalue: taction); inline;
begin
  if avalue in [low(actionmap)..high(actionmap)] then
    avalue:=actionmap[avalue];
  if fval=avalue then
    exit;
  fval:=avalue;
end;

begin
  setval(anone);
  if fval<>anone then
    halt(1);
  setval(aoldpaste);
  if fval<>apaste then
    halt(2);
  writeln('ok');
end.
