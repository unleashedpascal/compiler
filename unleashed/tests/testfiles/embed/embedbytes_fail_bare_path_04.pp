{ %FAIL }
program embedbytes_fail_bare_path_04;

{$mode unleashed}

begin
  // the path has no quotes
  if length({$embedbytes embedbytes_fail_bare_path_04.pp}) = 0 then halt(1);
end.
