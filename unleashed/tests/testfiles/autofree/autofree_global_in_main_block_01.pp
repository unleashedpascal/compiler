program autofree_global_in_main_block_01;

{$mode unleashed}

uses Classes;

var
  list: TStringList;

begin
  // the main block shares the global's lifetime, so this is allowed
  list := autofree TStringList.Create;
  list.Add('a');
  if list.Count <> 1 then halt(1);
end.
