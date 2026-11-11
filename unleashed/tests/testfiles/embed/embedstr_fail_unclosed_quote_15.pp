{ %FAIL }
program embedstr_fail_unclosed_quote_15;

{$mode unleashed}

// the quoted value never ends
{$embedstr src 'embed_fixture.dat' encrypt seed='abc}

begin
end.
