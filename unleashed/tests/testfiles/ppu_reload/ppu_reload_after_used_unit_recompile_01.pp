{ %PRECOMPILE=uppu_reload_01_root.pas,uppu_reload_01_cycle.pas,uppu_reload_01_side.pas %TOUCH=uppu_reload_01_root.pas %OPT=-dPPU_RELOAD_01_EXTRA }
program ppu_reload_after_used_unit_recompile_01;

// incremental build of a unit cycle: the root unit is recompiled with a
// changed interface, so its cycle partner (loaded from the ppu) is recompiled
// on the crc mismatch, and the side unit, loaded from its ppu with the cycle
// class in a var parameter, must be re-resolved against the recompiled defs
{$mode unleashed}

uses uppu_reload_01_root;

begin
  if rootValue <> 7 then halt(1);
end.
