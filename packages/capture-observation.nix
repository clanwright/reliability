{ pkgs, restic }:

pkgs.writeShellApplication {
  name = "restic-capture-observe";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.jq
  ];
  text = ''
    # This observes a successful native Restic hook; it never runs a backup.
    # METRICS_DIR is preexisting, absolute, and controlled by the administrator.
    umask 077
    temporary=()
    cleanup() {
      if (( ''${#temporary[@]} )); then
        rm -f -- "''${temporary[@]}" 2>/dev/null
      fi
    }
    trap cleanup EXIT
    stage='arguments'
    fail() { printf 'capture observation rejected: %s\n' "$stage" >&2; exit 1; }
    label() { [[ "$1" =~ ^[a-z][a-z0-9_-]*$ ]] || fail; }
    age() {
      [[ "$1" =~ ^[1-9][0-9]*$ ]] || fail
      jq -en --arg age "$1" '$age | tonumber | . > 0 and . <= 9007199254740991' >/dev/null || fail
    }
    metrics_directory() { [[ "$1" == /* && -d "$1" ]] || fail; }
    new_file() {
      temp_file=$(mktemp "$1" 2>/dev/null) || fail
      temporary+=("$temp_file")
    }
    attempt() {
      new_file "$metrics/.capture-attempt.XXXXXX"
      printf 'reliability_capture_attempt_success{app="%s",destination="%s"} %s\nreliability_capture_attempt_seconds{app="%s",destination="%s"} %s\n' \
        "$app" "$destination" "$1" "$app" "$destination" "$attempt_time" 2>/dev/null > "$temp_file" || fail
      chmod 644 "$temp_file" 2>/dev/null || fail
      mv -Tf -- "$temp_file" "$metrics/$app.$destination.attempt.prom" 2>/dev/null || fail
    }
    validate() {
      jq -se --arg app "$app" --arg format "$format" --argjson now "$observed" --argjson age "$max_age" \
        -f ${./capture-metadata.jq} "$1" >/dev/null 2>/dev/null || fail
    }

    [[ $# -ge 1 ]] || fail
    mode=$1; shift
    case "$mode" in
      start)
        [[ $# == 3 ]] || fail
        app=$1; destination=$2; metrics=$3
        label "$app"; label "$destination"; metrics_directory "$metrics"
        stage='attempt-start'
        attempt_time=$(date +%s 2>/dev/null) || fail
        attempt 0
        ;;
      observe)
        [[ $# -ge 7 ]] || fail
        app=$1; destination=$2; format=$3; max_age=$4
        input=$5; metrics=$6; invocation=$7
        shift 7
        label "$app"; label "$destination"; metrics_directory "$metrics"
        age "$max_age"
        [[ "$input" == /* && "$invocation" =~ ^[0-9a-f]{32}$ ]] || fail
        tag="reliability-invocation:$invocation"
        stage='snapshot-query'
        new_file "''${TMPDIR:-/tmp}/capture-snapshots.XXXXXX"
        snapshots=$temp_file
        ${restic}/bin/restic "$@" snapshots --json --tag "$tag" --path "$input" 2>/dev/null > "$snapshots" || fail
        stage='snapshot-identity'
        snapshot_id=$(jq -ser --arg input "$input" --arg tag "$tag" '
          if length == 1 and (.[0] | type == "array" and length == 1) then .[0][0]
          else error("snapshot cardinality") end |
          if .paths == [$input] and (.tags | type == "array" and index($tag) != null)
            and (.id | type == "string" and test("^[0-9a-f]{64}$"))
          then .id else error("snapshot identity") end
        ' "$snapshots" 2>/dev/null) || fail
        stage='metadata-read'
        new_file "''${TMPDIR:-/tmp}/capture-metadata.XXXXXX"
        metadata=$temp_file
        ${restic}/bin/restic "$@" dump "$snapshot_id" "$input/export.json" 2>/dev/null > "$metadata" || fail
        observed=$(date +%s 2>/dev/null) || fail
        stage='metadata-validation'
        validate "$metadata"
        stage='metadata-publication'
        new_file "$metrics/.capture-success.XXXXXX"
        jq -r --arg app "$app" --arg destination "$destination" --arg snapshot "$snapshot_id" --argjson observed "$observed" '
          def escape: gsub("\\\\"; "\\\\") | gsub("\""; "\\\"") | gsub("\n"; "\\n");
          ("app=\"" + $app + "\",destination=\"" + $destination + "\"") as $labels |
          "reliability_capture_started_seconds{" + $labels + "} " + (.captureStartedAt | tostring),
          "reliability_capture_completed_seconds{" + $labels + "} " + (.captureCompletedAt | tostring),
          "reliability_capture_observation_seconds{" + $labels + "} " + ($observed | tostring),
          "reliability_capture_snapshot_info{" + $labels + ",snapshot_id=\"" + $snapshot +
            "\",capture_id=\"" + (.captureId | escape) + "\"} 1"
        ' "$metadata" 2>/dev/null > "$temp_file" || fail
        chmod 644 "$temp_file" 2>/dev/null || fail
        mv -Tf -- "$temp_file" "$metrics/$app.$destination.success.prom" 2>/dev/null || fail
        # Metadata publication and completed-attempt publication are separate.
        # A final status failure leaves verified metadata and the pending event.
        stage='attempt-completion'
        attempt_time=$(date +%s 2>/dev/null) || fail
        attempt 1
        ;;
      *) fail ;;
    esac
  '';
}
