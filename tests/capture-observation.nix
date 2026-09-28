{ pkgs }:

let
  observer = import ../packages/capture-observation.nix { inherit pkgs; };
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
    mkdir -p "$out/artifacts"
    work=$(mktemp -d)
    mkdir -p "$work/input" "$work/metrics"
    export RESTIC_REPOSITORY="$work/repository"
    export RESTIC_PASSWORD_FILE="$work/password"
    export RESTIC_HOST=fixture-host
    export RESTIC_OBSERVER_RESTIC=${pkgs.restic}/bin/restic
    printf 'test-only-disposable-password\n' > "$RESTIC_PASSWORD_FILE"
    chmod 600 "$RESTIC_PASSWORD_FILE"
    restic version > "$out/check.log"
    restic --no-cache init > "$out/artifacts/init.log" 2>&1
    observer=restic-capture-observe
    format=vaultwarden-pg18-files-v1
    app=vaultwarden
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
      started=$((now - 300))
      completed=$((now - 290))
      jq -n --arg app "$app" --arg format "$format" --argjson started "$started" --argjson completed "$completed" '
        {schemaVersion:1,appId:$app,formatVersion:$format,captureId:"fixture-capture-1234",
         validatorStorePath:"/nix/store/fixture-validator",captureStartedAt:$started,captureCompletedAt:$completed}
      ' > "$source/export.json"
      printf 'fake application export\n' > "$source/data"
    }
    backup() {
      invocation
      restic --no-cache backup --tag "reliability-invocation:$invocation_id" "$source" > "$out/artifacts/backup-$serial.log" 2>&1
    }
    observe() {
      "$observer" observe "$app" "$destination" "$format" 3600 "$source" "$metrics" "$invocation_id" --no-cache
    }
    failed_attempt() {
      cmp "$success" "$work/previous-success.prom"
      # Assertions use the public metrics, not the adapter's private helpers.
      test "$(sed -n '1p' "$attempt")" = 'reliability_capture_attempt_success{app="vaultwarden",destination="fixture-a"} 0'
    }
    rejected_fixture() {
      name=$1
      cp "$success" "$work/previous-success.prom"
      if "$observer" admit "$app" "$format" 3600 "$source/export.json" > "$out/artifacts/admit-$name.log" 2>&1; then
        printf 'FAIL: admitted %s\n' "$name" >> "$out/check.log"; exit 1
      fi
      backup
      if observe > "$out/artifacts/observe-$name.log" 2>&1; then
        printf 'FAIL: observed %s\n' "$name" >> "$out/check.log"; exit 1
      fi
      failed_attempt
      pass "$name rejected; prior successful metrics preserved; attempt failed"
    }

    fixture
    "$observer" start "$app" "$destination" "$metrics"
    test ! -e "$success"
    "$observer" admit "$app" "$format" 3600 "$source/export.json"
    backup
    observe
    test "$(sed -n '1p' "$attempt")" = 'reliability_capture_attempt_success{app="vaultwarden",destination="fixture-a"} 1'
    test "$(sed -n '1p' "$success")" = "reliability_capture_started_seconds{app=\"$app\",destination=\"$destination\"} $started"
    test "$(sed -n '2p' "$success")" = "reliability_capture_completed_seconds{app=\"$app\",destination=\"$destination\"} $completed"
    test "$(stat -c %a "$success")" = 644
    cp "$success" "$work/first-success.prom"
    pass 'native backup exit 0, exact invocation tag and paths, capture timestamps, public metrics mode 0644'

    "$observer" start "$app" "$destination" "$metrics"
    cp "$work/first-success.prom" "$work/previous-success.prom"
    failed_attempt
    backup
    observe
    head -n 2 "$work/first-success.prom" > "$work/first-times"
    head -n 2 "$success" > "$work/reupload-times"
    cmp "$work/first-times" "$work/reupload-times"
    pass 'reupload retained original capture times; start retained previous capture success'

    for mutation in schema wrong-app wrong-format future inverted expired fractional missing-field wrong-type; do
      fixture
      case "$mutation" in
        schema) expression='.schemaVersion = 2' ;;
        wrong-app) expression='.appId = "livesync"' ;;
        wrong-format) expression='.formatVersion = "another-format"' ;;
        future) expression='.captureCompletedAt = 9007199254740991' ;;
        inverted) expression='.captureStartedAt = .captureCompletedAt + 1' ;;
        expired) expression='.captureStartedAt = 1 | .captureCompletedAt = 2' ;;
        fractional) expression='.captureStartedAt += 0.5' ;;
        missing-field) expression='del(.validatorStorePath)' ;;
        wrong-type) expression='.captureId = 123' ;;
      esac
      jq "$expression" "$source/export.json" > "$work/changed.json"
      cp "$work/changed.json" "$source/export.json"
      rejected_fixture "$mutation"
    done
    fixture
    printf '{ malformed metadata\n' > "$source/export.json"
    rejected_fixture malformed
    fixture
    cp "$source/export.json" "$work/extra.json"
    cat "$work/extra.json" >> "$source/export.json"
    rejected_fixture multiple-documents
    fixture
    rm "$source/export.json"
    rejected_fixture missing-export

    fixture
    backup
    cp "$success" "$work/previous-success.prom"
    if "$observer" observe livesync "$destination" "$format" 3600 "$source" "$metrics" "$invocation_id" --no-cache > "$out/artifacts/wrong-pair.log" 2>&1; then exit 1; fi
    cmp "$success" "$work/previous-success.prom"
    test ! -e "$metrics/livesync.$destination.success.prom"
    pass 'wrong application pair cannot publish capture success'

    cp "$success" "$work/previous-success.prom"
    if RESTIC_REPOSITORY="$work/nonexistent" observe > "$out/artifacts/inaccessible-repository.log" 2>&1; then exit 1; fi
    failed_attempt
    pass 'inaccessible repository preserves prior success'

    invocation_id=ffffffffffffffffffffffffffffffff
    if observe > "$out/artifacts/missing-invocation.log" 2>&1; then exit 1; fi
    failed_attempt
    pass 'missing invocation fails without latest-snapshot fallback'

    backup
    restic --no-cache backup --tag "reliability-invocation:$invocation_id" "$source" > "$out/artifacts/ambiguous-backup.log" 2>&1
    if observe > "$out/artifacts/ambiguous-invocation.log" 2>&1; then exit 1; fi
    failed_attempt
    pass 'ambiguous invocation is rejected'

    invocation
    mkdir -p "$work/extra-path"
    printf 'fake second path\n' > "$work/extra-path/file"
    restic --no-cache backup --tag "reliability-invocation:$invocation_id" "$source" "$work/extra-path" > "$out/artifacts/multiple-paths.log" 2>&1
    if observe > "$out/artifacts/wrong-paths.log" 2>&1; then exit 1; fi
    failed_attempt
    pass 'snapshot with additional paths is rejected'

    fixture
    jq '.captureId = "uuid-1234\\quote\"line\nnext"' "$source/export.json" > "$work/escaped.json"
    cp "$work/escaped.json" "$source/export.json"
    backup
    observe
    grep -F 'capture_id="uuid-1234\\quote\"line\nnext"} 1' "$success" >/dev/null
    test "$(wc -l < "$success")" -eq 4
    promtool check metrics --extended --lint=none < "$success" > "$out/artifacts/escaped-label-promtool.log" 2>&1
    promtool check metrics --extended --lint=none < "$attempt" > "$out/artifacts/attempt-promtool.log" 2>&1
    pass 'producer capture ID backslash, quote and newline safely escaped; Prometheus exposition parser accepted success and attempt metrics'

    # A partial Restic snapshot is real, but native ExecStartPost must never
    # invoke the observer after exit 3. The observer cannot infer backup exit
    # status from snapshot metadata; this test exercises that caller boundary.
    cp "$success" "$work/previous-success.prom"
    fixture
    invocation
    printf 'fake unreadable fixture\n' > "$source/unreadable"
    chmod 000 "$source/unreadable"
    "$observer" start "$app" "$destination" "$metrics"
    set +e
    restic --no-cache backup --tag "reliability-invocation:$invocation_id" "$source" > "$out/artifacts/partial-backup.log" 2>&1
    result=$?
    set -e
    chmod 600 "$source/unreadable"
    if test "$result" -eq 3; then
      restic --no-cache snapshots --json --tag "reliability-invocation:$invocation_id" > "$out/artifacts/partial-snapshot.json"
      jq -e 'length == 1' "$out/artifacts/partial-snapshot.json" >/dev/null
      failed_attempt
      pass 'actual unreadable-file backup exit 3 produced snapshot; success hook withheld, attempt failed'
    elif test "$result" -eq 0 && test "$(id -u)" -eq 0; then
      pass 'unreadable-file exit 3 fixture skipped as root; native success-hook responsibility remains required'
    else
      printf 'FAIL: expected unreadable-file backup exit 3, got %s\n' "$result" >> "$out/check.log"
      exit 1
    fi
    cp "$metrics"/*.prom "$out/artifacts/"
    pass 'local fixture observation only; no systemd, database-consistency or semantic recovery claim'
  ''
