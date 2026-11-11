program embedstr_path_with_space_06;

{$mode unleashed}

{$embedstr text 'embed fixture.txt'}
{$embedbytes data 'embed fixture.txt'}

begin
  if pos('hello fixture', text) <> 1 then halt(1);
  if length(data) <> length(text) then halt(2);
  if {$embedstr 'embed fixture.txt'} <> text then halt(3);
end.
