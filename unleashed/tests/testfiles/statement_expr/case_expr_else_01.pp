program case_expr_else_01;

{$mode unleashed}

begin
  for var d := 1 to 8 do
  begin
    var name := case d of
      1: 'Mon';
      2: 'Tue';
      3: 'Wed';
      4: 'Thu';
      5: 'Fri';
      6: 'Sat';
      7: 'Sun';
    else
      '?'
    end;
    if (d <= 7) and (Length(name) <> 3) then halt(1);
    if (d = 8) and (name <> '?') then halt(2);
  end;
end.
