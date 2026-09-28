{ pkgs }:

pkgs.writeShellApplication {
  name = "restic-capture-observe";
  runtimeInputs = with pkgs; [
    coreutils
    jq
    restic
  ];
  text = ''
    # This observes a successful native Restic hook; it never runs a backup.
    # METRICS_DIR is preexisting, absolute, and controlled by the administrator.
    umask 077
    temporary=()
    cleanup() {
      if (( ''${#temporary[@]} )); then
        rm -f -- "''${temporary[@]}"
      fi
    }
    trap cleanup EXIT
    fail() { printf '%s\n' 'capture observation rejected' >&2; exit 1; }
    label() { [[ "$1" =~ ^[a-z][a-z0-9_-]*$ ]] || fail; }
    age() {
      [[ "$1" =~ ^[1-9][0-9]*$ ]] || fail
      jq -en --arg age "$1" '$age | tonumber | . > 0 and . <= 9007199254740991' >/dev/null || fail
    }
    metrics_directory() { [[ "$1" == /* && -d "$1" ]] || fail; }
    new_file() {
      temp_file=$(mktemp "$1") || fail
      temporary+=("$temp_file")
    }
    attempt() {
      new_file "$metrics/.capture-attempt.XXXXXX"
      printf 'reliability_capture_attempt_success{app="%s",destination="%s"} %s\nreliability_capture_attempt_seconds{app="%s",destination="%s"} %s\n' \
        "$app" "$destination" "$1" "$app" "$destination" "$attempt_time" > "$temp_file"
      chmod 644 "$temp_file"
      mv -f -- "$temp_file" "$metrics/$app.$destination.attempt.prom"
    }
    validate() {
      jq -se --arg app "$app" --arg format "$format" --argjson now "$observed" --argjson age "$max_age" '
        def integer: type == "number" and . == floor and . > 0 and . <= 9007199254740991;
        length == 1 and (.[0] |
          type == "object" and
          .schemaVersion == 1 and
          .appId == $app and .formatVersion == $format and
          (.captureId | type == "string" and length > 0) and
          (.validatorStorePath | type == "string" and length > 0) and
          (.captureStartedAt | integer) and (.captureCompletedAt | integer) and
          .captureStartedAt <= .captureCompletedAt and
          .captureCompletedAt <= $now and $now - .captureStartedAt <= $age)
      ' "$1" >/dev/null 2>/dev/null || fail
    }

    [[ $# -ge 1 ]] || fail
    mode=$1; shift
    case "$mode" in
      start)
        [[ $# == 3 ]] || fail
        app=$1; destination=$2; metrics=$3
        label "$app"; label "$destination"; metrics_directory "$metrics"
        attempt_time=$(date +%s)
        attempt 0
        ;;
      admit)
        [[ $# == 4 ]] || fail
        app=$1; format=$2; max_age=$3; metadata=$4
        label "$app"; age "$max_age"
        observed=$(date +%s)
        validate "$metadata"
        ;;
      observe)
        [[ $# -ge 7 ]] || fail
        app=$1; destination=$2; format=$3; max_age=$4
        input=$5; metrics=$6; invocation=$7
        shift 7
        label "$app"; label "$destination"; metrics_directory "$metrics"
        attempt_time=$(date +%s)
        attempt 0
        age "$max_age"
        [[ "$input" == /* && "$invocation" =~ ^[0-9a-f]{32}$ ]] || fail
        tag="reliability-invocation:$invocation"
        restic_command="''${RESTIC_OBSERVER_RESTIC:-restic}"
        new_file "''${TMPDIR:-/tmp}/capture-snapshots.XXXXXX"
        snapshots=$temp_file
        "$restic_command" "$@" snapshots --json --tag "$tag" --path "$input" > "$snapshots" 2>/dev/null || fail
        snapshot_id=$(jq -ser --arg input "$input" --arg tag "$tag" '
          if length == 1 and (.[0] | type == "array" and length == 1) then .[0][0]
          else error("snapshot cardinality") end |
          if .paths == [$input] and (.tags | type == "array" and index($tag) != null)
            and (.id | type == "string" and test("^[0-9a-f]{64}$"))
          then .id else error("snapshot identity") end
        ' "$snapshots" 2>/dev/null) || fail
        new_file "''${TMPDIR:-/tmp}/capture-metadata.XXXXXX"
        metadata=$temp_file
        "$restic_command" "$@" dump "$snapshot_id" "$input/export.json" > "$metadata" 2>/dev/null || fail
        observed=$(date +%s)
        validate "$metadata"
        new_file "$metrics/.capture-success.XXXXXX"
        jq -r --arg app "$app" --arg destination "$destination" --arg snapshot "$snapshot_id" --argjson observed "$observed" '
          def escape: gsub("\\\\"; "\\\\") | gsub("\""; "\\\"") | gsub("\n"; "\\n");
          ("app=\"" + $app + "\",destination=\"" + $destination + "\"") as $labels |
          "reliability_capture_started_seconds{" + $labels + "} " + (.captureStartedAt | tostring),
          "reliability_capture_completed_seconds{" + $labels + "} " + (.captureCompletedAt | tostring),
          "reliability_capture_observation_seconds{" + $labels + "} " + ($observed | tostring),
          "reliability_capture_snapshot_info{" + $labels + ",snapshot_id=\"" + $snapshot +
            "\",capture_id=\"" + (.captureId | escape) + "\"} 1"
        ' "$metadata" > "$temp_file" 2>/dev/null || fail
        chmod 644 "$temp_file"
        mv -f -- "$temp_file" "$metrics/$app.$destination.success.prom"
        attempt 1
        ;;
      *) fail ;;
    esac
  '';
}
