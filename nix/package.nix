{
  lib,
  writeShellApplication,
  python3,
  restic,
  rclone,
  bubblewrap ? null,
}:

writeShellApplication {
  name = "reliability";
  runtimeInputs = [
    python3
    restic
    rclone
  ]
  ++ lib.optional (bubblewrap != null) bubblewrap;
  text = ''
    exec ${python3}/bin/python3 ${../src/reliability.py} "$@"
  '';
}
