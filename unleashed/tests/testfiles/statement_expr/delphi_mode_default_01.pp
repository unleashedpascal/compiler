program delphi_mode_default_01;

{ statement expressions are on by default in mode delphi }
{$mode delphi}

type
  TE = (eA, eB, eC);

function raiser(doRaise: boolean): string;
begin
  result := 'ok';
  if doRaise then raise TObject.Create;
end;

var
  s: string;
  e: TE;
begin
  s := if 0 < 1 then 'foo' else 'bar';
  if s <> 'foo' then halt(1);
  e := eC;
  s := case e of
    eA: 'a';
    eB: 'b';
  else
    'other'
  end;
  if s <> 'other' then halt(2);
  s := try raiser(true) except 'err' end;
  if s <> 'err' then halt(3);
end.
