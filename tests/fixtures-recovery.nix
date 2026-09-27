{ lib, ... }:

{
  # Test-only stand-in for the external Primitives public recovery contract.
  options.clanwright.recovery.units = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          contractVersion = lib.mkOption { type = lib.types.int; };
          formatVersion = lib.mkOption { type = lib.types.str; };
          stateRefs = lib.mkOption { type = lib.types.listOf lib.types.str; };
          captureCommand = lib.mkOption { type = lib.types.str; };
          validateCommand = lib.mkOption { type = lib.types.str; };
        };
      }
    );
    default = { };
  };
}
