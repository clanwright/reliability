{ pkgs }:

pkgs.runCommand "reliability-restic-integration"
  {
    nativeBuildInputs = with pkgs; [
      coreutils
      jq
      restic
    ];
  }
  ''
    set -euo pipefail
    mkdir -p "$out/artifacts"
    work=$(mktemp -d)
    export HOME="$work"
    export RESTIC_HOST=fixture-host

    restic version > "$out/artifacts/versions.txt"
    jq --version >> "$out/artifacts/versions.txt"
    cp "$out/artifacts/versions.txt" "$out/check.log"

    mkdir -p "$work/source/nested"
    printf 'fixture: first version\n' > "$work/source/nested/note.txt"
    printf '\000\001\376\377' > "$work/source/nested/bytes.bin"
    printf 'test-only-primary\n' > "$work/password-primary"
    printf 'test-only-second\n' > "$work/password-second"
    printf 'test-only-incorrect\n' > "$work/password-incorrect"
    chmod 600 "$work"/password-*

    cd "$work"
    export RESTIC_REPOSITORY="$work/repo-primary"
    export RESTIC_PASSWORD_FILE="$work/password-primary"
    restic --no-cache init > "$out/artifacts/init-primary.log" 2>&1
    printf 'PASS: initialized disposable primary repository\n' >> "$out/check.log"
    restic --no-cache backup source > "$out/artifacts/backup-primary.log" 2>&1
    restic --no-cache check > "$out/artifacts/check-primary.log" 2>&1
    restic --no-cache check --read-data > "$out/artifacts/read-check-primary.log" 2>&1
    restic --no-cache restore latest --target restored --verify > "$out/artifacts/restore-primary.log" 2>&1
    cmp source/nested/note.txt restored/source/nested/note.txt
    cmp source/nested/bytes.bin restored/source/nested/bytes.bin
    printf 'PASS: backup, metadata and data checks, verified restore, exact fixture bytes\n' >> "$out/check.log"

    export RESTIC_REPOSITORY="$work/repo-second"
    export RESTIC_PASSWORD_FILE="$work/password-second"
    restic --no-cache init > "$out/artifacts/init-second.log" 2>&1
    export RESTIC_PASSWORD_FILE="$work/password-incorrect"
    if restic --no-cache backup source > "$out/artifacts/failed-second-backup.log" 2>&1; then
      printf 'FAIL: second repository accepted incorrect test password\n' >> "$out/check.log"
      exit 1
    fi
    export RESTIC_REPOSITORY="$work/repo-primary"
    export RESTIC_PASSWORD_FILE="$work/password-primary"
    restic --no-cache snapshots --json > "$out/artifacts/primary-after-second-failure.json"
    jq -e 'length == 1' "$out/artifacts/primary-after-second-failure.json" > /dev/null
    restic --no-cache check > "$out/artifacts/check-after-second-failure.log" 2>&1
    printf 'PASS: failed second destination left primary snapshot readable\n' >> "$out/check.log"

    export RESTIC_REPOSITORY="$work/repo-second"
    export RESTIC_PASSWORD_FILE="$work/password-second"
    restic --no-cache backup source > "$out/artifacts/backup-second.log" 2>&1
    restic --no-cache snapshots --json > "$out/artifacts/second-snapshots.json"
    jq -e 'length == 1' "$out/artifacts/second-snapshots.json" > /dev/null
    restic --no-cache restore latest --target restored-second --verify > "$out/artifacts/restore-second.log" 2>&1
    cmp source/nested/note.txt restored-second/source/nested/note.txt
    cmp source/nested/bytes.bin restored-second/source/nested/bytes.bin
    printf 'PASS: second repository backup restored exact fixture bytes\n' >> "$out/check.log"

    export RESTIC_REPOSITORY="$work/repo-primary"
    export RESTIC_PASSWORD_FILE="$work/password-primary"
    printf 'fixture: second version\n' > source/nested/note.txt
    restic --no-cache backup source > "$out/artifacts/backup-primary-again.log" 2>&1
    restic --no-cache snapshots --json > "$out/artifacts/before-retention.json"
    jq -e 'length == 2' "$out/artifacts/before-retention.json" > /dev/null
    restic --no-cache forget --keep-last 1 --dry-run > "$out/artifacts/retention-dry-run.log" 2>&1
    restic --no-cache snapshots --json > "$out/artifacts/after-retention.json"
    jq -r '.[].id' "$out/artifacts/before-retention.json" | sort > "$out/artifacts/ids-before.txt"
    jq -r '.[].id' "$out/artifacts/after-retention.json" | sort > "$out/artifacts/ids-after.txt"
    cmp "$out/artifacts/ids-before.txt" "$out/artifacts/ids-after.txt"
    printf 'PASS: retention dry run preserved both primary snapshot IDs\n' >> "$out/check.log"
  ''
