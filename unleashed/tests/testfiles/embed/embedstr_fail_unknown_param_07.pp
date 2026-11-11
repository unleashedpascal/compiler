{ %FAIL }
program embedstr_fail_unknown_param_07;

{$mode unleashed}

// a word after the path that is not a parameter
{$embedstr src 'embed_fixture.dat' shrink}

begin
end.
