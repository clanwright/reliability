{ pkgs }:

let
  observer = import ../packages/capture-observation.nix {
    inherit pkgs;
    restic = pkgs.restic;
  };
  # Test-only dependency injection makes the final atomic status write fail
  # after a real snapshot dump. The production observer has no runtime override.
  finalWriteRestic = pkgs.writeShellScriptBin "restic" ''
    ${pkgs.restic}/bin/restic "$@"
    result=$?
    if test "$result" -eq 0 && test "''${2:-}" = dump; then
      rm "$TEST_ATTEMPT"
      mkdir "$TEST_ATTEMPT"
    fi
    exit "$result"
  '';
  finalWriteObserver = import ../packages/capture-observation.nix {
    inherit pkgs;
    restic = finalWriteRestic;
  };
in
pkgs.runCommand "reliability-capture-observation"
  {
    nativeBuildInputs = with pkgs; [
      coreutils
      jq
      restic
      observer
      prometheus.cli
    ];
  }
  ''
    set -euo pipefail
    mkdir -p "$out"
    work=$(mktemp -d)
    trap 'result=$?; if test "$result" -ne 0; then cat "$work"/*.log >&2; fi' EXIT
    mkdir -p "$work/input" "$work/metrics"
    export RESTIC_REPOSITORY="$work/repository"
    export RESTIC_PASSWORD_FILE="$work/password"
    export RESTIC_HOST=fixture-host
    printf 'test-only-disposable-password\n' > "$RESTIC_PASSWORD_FILE"
    chmod 600 "$RESTIC_PASSWORD_FILE"
    restic --no-cache init > "$work/init.log" 2>&1
    app=vaultwarden
    format=vaultwarden-pg18-files-v1
    destination=fixture-a
    source="$work/input"
    metrics="$work/metrics"
    success="$metrics/$app.$destination.success.prom"
    attempt="$metrics/$app.$destination.attempt.prom"
    serial=0
    pass() { printf 'PASS: %s\n' "$1" >> "$out/check.log"; }
    invocation() { serial=$((serial + 1)); printf -v invocation_id '%032x' "$serial"; }
    fixture() {
      now=$(date +%s)
      started=$((now - 300)); completed=$((now - 290))
      jq -n --arg app "$app" --arg format "$format" --argjson started "$started" --argjson completed "$completed" '
        {schemaVersion:1,appId:$app,formatVersion:$format,captureId:"uuid-1234\\quote\"line\nnext",
         validatorStorePath:"/nix/store/fixture-validator",captureStartedAt:$started,captureCompletedAt:$completed}
      ' > "$source/export.json"
      printf 'fake application export\n' > "$source/data"
      printf '\000\001\376\377' > "$source/bytes"
    }
    backup() {
      invocation
      restic --no-cache backup --tag "reliability-invocation:$invocation_id" "$source" > "$work/backup.log" 2>&1
    }
    start() { restic-capture-observe start "$app" "$destination" "$metrics"; }
    observe() { restic-capture-observe observe "$app" "$destination" "$format" 3600 "$source" "$metrics" "$invocation_id" --no-cache; }
    pending() {
      test "$(sed -n '1p' "$attempt")" = 'reliability_capture_attempt_success{app="vaultwarden",destination="fixture-a"} 0'
    }
    rejected() {
      cp "$success" "$work/previous-success"
      start
      cp "$attempt" "$work/previous-attempt"
      if test "$1" = 'real malformed dump'; then sleep 1; fi
      if observe > "$work/rejected.log" 2>&1; then exit 1; fi
      cmp "$success" "$work/previous-success"
      cmp "$attempt" "$work/previous-attempt"
      pending
      pass "$1 rejected; prior capture and pending event retained"
    }

    # Exercise the same predicate as the runtime without creating snapshots for
    # every metadata mutation. Fixed time makes boundary assertions reproducible.
    fixture
    jq '.captureStartedAt = 9700 | .captureCompletedAt = 9710' "$source/export.json" > "$work/valid.json"
    validate() { jq -se --arg app "$app" --arg format "$format" --argjson now 10000 --argjson age 300 -f ${../packages/capture-metadata.jq} "$1" >/dev/null 2>&1; }
    validate "$work/valid.json"
    for expression in '.schemaVersion = 2' '.appId = "livesync"' '.formatVersion = "other"' '.captureCompletedAt = 10001' '.captureStartedAt = .captureCompletedAt + 1' '.captureStartedAt = 9699' '.captureStartedAt += 0.5' 'del(.validatorStorePath)' '.captureId = 123' '.captureStartedAt = 0' '.captureCompletedAt = 9007199254740992' '.captureId = ""' '.validatorStorePath = ""' '.captureStartedAt = "9700"' '.'; do
      if test "$expression" = '.'; then printf '[]\n' > "$work/invalid.json"; else jq "$expression" "$work/valid.json" > "$work/invalid.json"; fi
      if validate "$work/invalid.json"; then exit 1; fi
    done
    printf '{ malformed\n' > "$work/invalid.json"
    if validate "$work/invalid.json"; then exit 1; fi
    cat "$work/valid.json" "$work/valid.json" > "$work/invalid.json"
    if validate "$work/invalid.json"; then exit 1; fi
    : > "$work/invalid.json"
    if validate "$work/invalid.json"; then exit 1; fi
    if validate "$work/missing.json"; then exit 1; fi
    pass 'shared metadata predicate: schema, identity, types, bounds, age equality, malformed and document cardinality'

    before_start=$(date +%s)
    start
    pending
    test ! -e "$success"
    start_time=$(awk 'NR == 2 {print $NF}' "$attempt")
    test "$start_time" -ge "$before_start"
    test "$start_time" -le "$(date +%s)"
    backup
    sleep 1
    observe
    finish_time=$(awk 'NR == 2 {print $NF}' "$attempt")
    test "$finish_time" -gt "$start_time"
    test "$(sed -n '1p' "$attempt")" = 'reliability_capture_attempt_success{app="vaultwarden",destination="fixture-a"} 1'
    test "$(sed -n '1p' "$success")" = "reliability_capture_started_seconds{app=\"$app\",destination=\"$destination\"} $started"
    test "$(sed -n '2p' "$success")" = "reliability_capture_completed_seconds{app=\"$app\",destination=\"$destination\"} $completed"
    test "$(stat -c %a "$success")" = 644
    test "$(stat -c %a "$attempt")" = 644
    grep -F 'capture_id="uuid-1234\\quote\"line\nnext"} 1' "$success" >/dev/null
    test "$(wc -l < "$success")" -eq 4
    promtool check metrics --extended --lint=none < "$success" > "$work/promtool.log" 2>&1
    promtool check metrics --extended --lint=none < "$attempt" >> "$work/promtool.log" 2>&1
    restic --no-cache check > "$work/check.log" 2>&1
    restic --no-cache check --read-data > "$work/read-data.log" 2>&1
    restic --no-cache restore latest --target "$work/restored" --verify > "$work/restore.log" 2>&1
    cmp "$source/data" "$work/restored$source/data"
    cmp "$source/bytes" "$work/restored$source/bytes"
    cmp "$source/export.json" "$work/restored$source/export.json"
    pass 'exact invocation/path dump, escaped public metrics, completion event, repository structure/read-data and byte-exact restore'

    head -n 2 "$success" > "$work/original-times"
    start
    backup
    observe
    head -n 2 "$success" > "$work/reupload-times"
    cmp "$work/original-times" "$work/reupload-times"
    successful_invocation=$invocation_id
    pass 'reupload retains producer capture age'

    printf '{ malformed metadata\n' > "$source/export.json"
    backup
    rejected 'real malformed dump'
    fixture
    jq '.captureStartedAt = 1 | .captureCompletedAt = 2' "$source/export.json" > "$work/stale.json"
    cp "$work/stale.json" "$source/export.json"
    backup
    rejected 'real stale dump'
    fixture
    backup
    saved_invocation=$invocation_id
    invocation_id=ffffffffffffffffffffffffffffffff
    rejected 'missing invocation'
    invocation_id=$saved_invocation
    cp "$success" "$work/previous-success"
    start
    cp "$attempt" "$work/previous-attempt"
    if RESTIC_REPOSITORY="$work/nonexistent" observe > "$work/inaccessible.log" 2>&1; then exit 1; fi
    cmp "$success" "$work/previous-success"
    cmp "$attempt" "$work/previous-attempt"
    pass 'inaccessible repository fails closed'
    restic --no-cache backup --tag "reliability-invocation:$invocation_id" "$source" > "$work/ambiguous-backup.log" 2>&1
    rejected 'ambiguous invocation'
    invocation
    mkdir -p "$work/extra-path"
    printf 'extra\n' > "$work/extra-path/file"
    restic --no-cache backup --tag "reliability-invocation:$invocation_id" "$source" "$work/extra-path" > "$work/extra-backup.log" 2>&1
    rejected 'additional snapshot path'

    # Native success-hook gating is separately verified at the NixOS unit layer.
    # This fixture must actually produce exit 3; root is unsupported, not skipped.
    test "$(id -u)" -ne 0
    fixture
    invocation
    printf 'unreadable fixture\n' > "$source/unreadable"
    chmod 000 "$source/unreadable"
    cp "$success" "$work/previous-success"
    start
    set +e
    restic --no-cache backup --tag "reliability-invocation:$invocation_id" "$source" > "$work/partial.log" 2>&1
    result=$?
    set -e
    chmod 600 "$source/unreadable"
    test "$result" -eq 3
    restic --no-cache snapshots --json --tag "reliability-invocation:$invocation_id" | jq -e 'length == 1' >/dev/null
    cmp "$success" "$work/previous-success"
    pending
    pass 'actual partial exit 3 with snapshot: withheld observer leaves attempt pending'

    # Publish truthful verified capture metadata, but do not certify an attempt
    # whose final atomic status write fails.
    invocation_id=$successful_invocation
    start
    export TEST_ATTEMPT="$attempt"
    if ${finalWriteObserver}/bin/restic-capture-observe observe "$app" "$destination" "$format" 3600 "$source" "$metrics" "$invocation_id" --no-cache > "$work/final-write.log" 2>&1; then exit 1; fi
    test -d "$attempt"
    test -z "$(ls -A "$attempt")"
    head -n 2 "$success" > "$work/final-times"
    cmp "$work/original-times" "$work/final-times"
    pass 'final status-write failure returns failure; verified metadata truthful and latest attempt uncertified'
  ''
