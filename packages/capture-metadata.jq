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
