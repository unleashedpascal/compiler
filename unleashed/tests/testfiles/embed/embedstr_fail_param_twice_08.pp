{ %FAIL }
program embedstr_fail_param_twice_08;

{$mode unleashed}

// the same parameter twice
{$embedstr src 'embed_fixture.dat' compress compress=zlib}

begin
end.
