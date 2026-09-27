{ pkgs }:

if !pkgs.stdenv.hostPlatform.isLinux then
  null
else if pkgs.lib.versionAtLeast pkgs.bubblewrap.version "0.13.0" then
  pkgs.bubblewrap
else
  pkgs.bubblewrap.overrideAttrs (previous: {
    version = "0.13.0";
    src = pkgs.fetchurl {
      url = "https://github.com/containers/bubblewrap/releases/download/v0.13.0/bubblewrap-0.13.0.tar.xz";
      hash = "sha256-RzQjdHPA5daV5OkDSjTkOy2/UWRlW9E/pZrjdrK3p2U=";
    };
    meta = previous.meta // {
      changelog = "https://github.com/containers/bubblewrap/releases/tag/v0.13.0";
    };
  })
