program embedstr_double_quoted_path_05;

{$mode unleashed}

{$embedstr src "embedstr_double_quoted_path_05.pp"}

const
  MARKER = 'DOUBLE_QUOTED_Q7M2X_MARKER';

begin
  if pos(MARKER, src) = 0 then halt(1);
  if pos(MARKER, {$embedstr "embedstr_double_quoted_path_05.pp"}) = 0 then halt(2);
end.
