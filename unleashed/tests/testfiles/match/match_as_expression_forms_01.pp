{$mode unleashed}
{ match as expression }
program match_as_expression_forms_01;

procedure TestBasic;
var
  x: Integer;
  s: String;
begin
  x := 2;
  s := match x of
    1: 'one';
    2: 'two';
    3: 'three';
    _: 'other';
  end;
  if s <> 'two' then Halt(1);
end;

procedure TestWithElse;
var
  x: Integer;
  s: String;
begin
  x := 99;
  s := match x of
    1: 'one';
    2: 'two';
  else 'unknown' end;
  if s <> 'unknown' then Halt(2);
end;

procedure TestConditionBased;
var
  x: Integer;
  s: String;
begin
  x := 50;
  s := match
    x > 100: 'big';
    x > 10:  'medium';
    _:       'small';
  end;
  if s <> 'medium' then Halt(3);
end;

begin
  TestBasic;
  TestWithElse;
  TestConditionBased;
  WriteLn('OK');
end.
