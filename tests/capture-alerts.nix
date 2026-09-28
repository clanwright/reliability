{ pkgs }:

let
  group = import ../examples/capture-alerts.nix { attemptGracePeriod = "5m"; };
  rules = pkgs.writeText "capture-alerts.json" (builtins.toJSON { groups = [ group ]; });
  pairs =
    builtins.concatMap
      (
        app:
        map (destination: { inherit app destination; }) [
          "a"
          "b"
        ]
      )
      [
        "vaultwarden"
        "livesync"
      ];
  target = {
    job = "reliability";
    instance = "fixture.invalid:9100";
  };
  labels =
    attrs:
    builtins.concatStringsSep "," (
      pkgs.lib.mapAttrsToList (key: value: "${key}=${builtins.toJSON value}") attrs
    );
  series = name: attrs: value: {
    series = "${name}{${labels attrs}}";
    # Evaluate at Unix time 108000s; repeated samples keep the scrape current.
    values = "${toString value}x32";
  };
  baseline = {
    attempt_success = 1;
    attempt_seconds = 107200;
    started_seconds = 107000;
    completed_seconds = 107100;
    observation_seconds = 107200;
    snapshot_info = 1;
  };
  input =
    transform:
    builtins.concatMap (
      pair:
      pkgs.lib.mapAttrsToList (
        suffix: value:
        series "reliability_capture_${suffix}" (
          target
          // pair
          // pkgs.lib.optionalAttrs (suffix == "snapshot_info") {
            snapshot_id = "fixture-snapshot";
            capture_id = "fixture-capture";
          }
        ) value
      ) (transform pair)
    ) pairs;
  first = pair: pair.app == "vaultwarden" && pair.destination == "a";
  altered = values: pair: baseline // pkgs.lib.optionalAttrs (first pair) values;
  up = value: [ (series "up" target value) ];
  expected = alert: attrs: {
    exp_labels =
      target
      // attrs
      // {
        severity =
          (builtins.head (builtins.filter (item: item.alert == alert) group.rules)).labels.severity;
      };
    exp_annotations =
      (builtins.head (builtins.filter (item: item.alert == alert) group.rules)).annotations;
  };
  pairAlert = alert: [
    (expected alert {
      app = "vaultwarden";
      destination = "a";
    })
  ];
  test = name: inputs: alerts: {
    inherit name;
    start_timestamp = 106200;
    interval = "1m";
    input_series = inputs;
    # Assert every rule in every case, including absence of unrelated alerts.
    alert_rule_test = map (rule: {
      eval_time = "30m";
      alertname = rule.alert;
      exp_alerts = alerts.${rule.alert} or [ ];
    }) group.rules;
  };
  graceInputs = map (
    sample:
    sample
    // pkgs.lib.optionalAttrs (
      sample.series == "reliability_capture_attempt_success{${
        labels (
          target
          // {
            app = "vaultwarden";
            destination = "a";
          }
        )
      }}"
    ) { values = "1x26 0x6"; }
  ) (input (_: baseline));
  cases = [
    (test "all four pairs healthy" (up 1 ++ input (_: baseline)) { })
    (test "old capture recently observed remains critical"
      (
        up 1
        ++ input (altered {
          started_seconds = 1;
        })
      )
      {
        ReliabilityCaptureAgeCritical = pairAlert "ReliabilityCaptureAgeCritical";
      }
    )
    (test "warning uses capture start"
      (
        up 1
        ++ input (altered {
          started_seconds = 38000;
        })
      )
      {
        ReliabilityCaptureAgeWarning = pairAlert "ReliabilityCaptureAgeWarning";
      }
    )
    (test "one missing expected pair" (up 1 ++ input (pair: if first pair then { } else baseline)) {
      ReliabilityCaptureMetricsMissing = pairAlert "ReliabilityCaptureMetricsMissing";
    })
    (test "one missing field despite observation"
      (
        up 1
        ++ input (
          pair: if first pair then builtins.removeAttrs baseline [ "started_seconds" ] else baseline
        )
      )
      {
        ReliabilityCaptureMetricsMissing = pairAlert "ReliabilityCaptureMetricsMissing";
      }
    )
    (test "snapshot provenance missing despite timestamps"
      (
        up 1
        ++ input (pair: if first pair then builtins.removeAttrs baseline [ "snapshot_info" ] else baseline)
      )
      {
        ReliabilityCaptureMetricsMissing = pairAlert "ReliabilityCaptureMetricsMissing";
      }
    )
    (test "every expected pair missing" (up 1) {
      ReliabilityCaptureMetricsMissing = map (
        pair: expected "ReliabilityCaptureMetricsMissing" pair
      ) pairs;
    })
    (test "failed attempt preserves earlier success"
      (
        up 1
        ++ input (altered {
          attempt_success = 0;
          attempt_seconds = 107900;
        })
      )
      {
        ReliabilityCaptureAttemptFailed = pairAlert "ReliabilityCaptureAttemptFailed";
      }
    )
    (
      let
        grace = test "running attempt gets grace before failure fires" (up 1 ++ graceInputs) { };
      in
      grace
      // {
        alert_rule_test = grace.alert_rule_test ++ [
          {
            eval_time = "32m";
            alertname = "ReliabilityCaptureAttemptFailed";
            exp_alerts = pairAlert "ReliabilityCaptureAttemptFailed";
          }
        ];
      }
    )
    (test "stale observation despite fresh scrape"
      (
        up 1
        ++ input (altered {
          started_seconds = 106000;
          completed_seconds = 106100;
          observation_seconds = 106200;
        })
      )
      {
        ReliabilityCaptureObservationStale = pairAlert "ReliabilityCaptureObservationStale";
      }
    )
    (test "future capture timestamp"
      (
        up 1
        ++ input (altered {
          started_seconds = 108001;
        })
      )
      {
        ReliabilityCaptureTimestampsInvalid = pairAlert "ReliabilityCaptureTimestampsInvalid";
      }
    )
    (test "host down with retained samples" (up 0 ++ input (_: baseline)) {
      ReliabilityCaptureTargetUnavailable = [ (expected "ReliabilityCaptureTargetUnavailable" { }) ];
    })
    (test "target absent even with retained samples" (input (_: baseline)) {
      ReliabilityCaptureTargetUnavailable = [ (expected "ReliabilityCaptureTargetUnavailable" { }) ];
    })
  ];
  fixtures = pkgs.writeText "capture-alerts-tests.json" (
    builtins.toJSON {
      rule_files = [ rules ];
      evaluation_interval = "1m";
      tests = cases;
    }
  );
  escaped = pkgs.writeText "capture-alerts-escaped.json" (
    builtins.toJSON {
      groups = [
        (import ../examples/capture-alerts.nix {
          job = "quoted\"job\\suffix";
          instance = "fixture.invalid:9100\nquoted\"";
          warningAgeSeconds = 3600;
          criticalAgeSeconds = 7200;
          observationMaxAgeSeconds = 1800;
        })
      ];
    }
  );
in
pkgs.runCommand "reliability-capture-alerts" { nativeBuildInputs = [ pkgs.prometheus.cli ]; } ''
  mkdir -p "$out"
  cp ${rules} "$out/rules.json"
  cp ${fixtures} "$out/tests.json"
  cp ${escaped} "$out/escaped-rules.json"
  promtool --version > "$out/promtool-version.txt"
  promtool check rules ${rules} ${escaped} > "$out/check-rules.txt" 2>&1
  cat "$out/check-rules.txt"
  promtool test rules ${fixtures} > "$out/test-rules.txt" 2>&1
  cat "$out/test-rules.txt"
''
