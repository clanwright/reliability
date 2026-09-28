{
  job ? "reliability",
  instance ? "fixture.invalid:9100",
  warningAgeSeconds ? 64800,
  criticalAgeSeconds ? 86400,
  observationMaxAgeSeconds ? 900,
  attemptGracePeriod ? "2h5m",
}:

let
  # Evaluate on an independent Prometheus host. Serialize this group as
  # builtins.toJSON { groups = [ (import ./capture-alerts.nix { ... }) ]; }
  # in pkgs.writeText and pass the resulting file to services.prometheus.ruleFiles.
  # Consumers choose scrape identity and ages, including an observation age
  # appropriate to their backup schedule. No snapshot timestamp is used here.
  target = "job=${builtins.toJSON job},instance=${builtins.toJSON instance}";
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
  metrics = [
    "attempt_success"
    "attempt_seconds"
    "started_seconds"
    "completed_seconds"
    "observation_seconds"
    "snapshot_info"
  ];
  series =
    suffix:
    "reliability_capture_${suffix}{${target},app=~\"vaultwarden|livesync\",destination=~\"a|b\"}";
  missing = builtins.concatStringsSep " or " (
    builtins.concatMap (
      pair:
      map (
        suffix:
        "absent(reliability_capture_${suffix}{${target},app=${builtins.toJSON pair.app},destination=${builtins.toJSON pair.destination}})"
      ) metrics
    ) pairs
  );
  timestamps = [
    "attempt_seconds"
    "started_seconds"
    "completed_seconds"
    "observation_seconds"
  ];
  invalid = builtins.concatStringsSep " or " (
    builtins.concatMap (suffix: [
      "(${series suffix} > time())"
      "(${series suffix} <= 0)"
    ]) timestamps
    ++ [
      "(${series "started_seconds"} > ${series "completed_seconds"})"
      "(${series "completed_seconds"} > ${series "observation_seconds"})"
      "((${series "attempt_success"} != 0) and (${series "attempt_success"} != 1))"
    ]
  );
  rule = alert: severity: summary: expr: {
    inherit alert expr;
    labels = { inherit severity; };
    annotations = { inherit summary; };
  };
in
assert builtins.isString job && builtins.isString instance;
assert builtins.isString attemptGracePeriod;
assert builtins.isInt warningAgeSeconds && warningAgeSeconds > 0;
assert builtins.isInt criticalAgeSeconds && criticalAgeSeconds > warningAgeSeconds;
assert builtins.isInt observationMaxAgeSeconds && observationMaxAgeSeconds > 0;
{
  name = "reliability-capture";
  interval = "1m";
  rules = [
    (
      (rule "ReliabilityCaptureTargetUnavailable" "critical"
        "Capture observation scrape target is unavailable."
        "(up{${target}} == 0) or absent(up{${target}})"
      )
      // {
        "for" = "5m";
      }
    )
    (
      (rule "ReliabilityCaptureMetricsMissing" "critical"
        "An expected application destination capture metric is missing."
        missing
      )
      // {
        "for" = "5m";
      }
    )
    (rule "ReliabilityCaptureTimestampsInvalid" "critical"
      "Capture observation has invalid or future timestamps."
      "max by (job, instance, app, destination) (${invalid})"
    )
    (
      (rule "ReliabilityCaptureAttemptFailed" "critical"
        "Capture attempt failed or has not completed within the consumer grace period."
        "${series "attempt_success"} == 0"
      )
      // {
        "for" = attemptGracePeriod;
      }
    )
    (rule "ReliabilityCaptureObservationStale" "critical"
      "Capture observation is older than the consumer freshness limit."
      "time() - ${series "observation_seconds"} > ${toString observationMaxAgeSeconds}"
    )
    (rule "ReliabilityCaptureAgeWarning" "warning"
      "Capture start is older than the consumer warning limit."
      "(time() - ${series "started_seconds"} > ${toString warningAgeSeconds}) and (time() - ${series "started_seconds"} <= ${toString criticalAgeSeconds})"
    )
    (rule "ReliabilityCaptureAgeCritical" "critical"
      "Capture start is older than the consumer critical limit."
      "time() - ${series "started_seconds"} > ${toString criticalAgeSeconds}"
    )
  ];
}
