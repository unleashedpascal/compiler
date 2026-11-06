{ %FAIL }
program strinterp_fail_charconst_wide_01;
// a char constant above 255 cannot be glued to an interpolated string

{$mode unleashed}

begin
  var name := 'Bob';
  writeln($'a{name}'#$1F600'b');
end.
