{ %FAIL }
program embedstr_fail_bare_path_04;

{$mode unleashed}

// the path has no quotes
{$embedstr src embedstr_fail_bare_path_04.pp}

begin
end.
