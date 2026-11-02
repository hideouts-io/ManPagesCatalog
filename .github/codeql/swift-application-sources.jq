# Missing or empty notification locations contribute no files; null/non-array locations are invalid.
# Validate located artifacts before comparing the complete nonempty application source set.
def require_object($field):
  if type == "object" then . else error($field + " must be an object") end;

def require_array($field):
  if type == "array" then . else error($field + " must be an array") end;

def require_nonempty_array($field):
  require_array($field) |
  if length > 0 then . else error($field + " must not be empty") end;

def require_nonempty_text($field):
  if type == "string" and length > 0 then . else error($field + " must be a nonempty string") end;

[
  require_object("Swift SARIF") |
  .runs | require_nonempty_array("Swift SARIF runs") | .[] |
  require_object("Swift SARIF run") |
  .invocations | require_nonempty_array("Swift SARIF invocations") | .[] |
  require_object("Swift SARIF invocation") |
  if .executionSuccessful != true then error("Swift analysis execution was not successful") else . end |
  .toolExecutionNotifications | require_array("Swift SARIF notifications") | .[] |
  require_object("Swift SARIF notification") |
  (.descriptor | require_object("Notification descriptor") |
    .id | require_nonempty_text("Notification descriptor id")) as $identifier |
  if $identifier == "swift/diagnostics/successfully-extracted-files" then
    if has("locations") then
      .locations | require_array("Successful-extraction locations") | .[] |
      require_object("Successful-extraction location") |
      .physicalLocation | require_object("Successful-extraction physical location") |
      .artifactLocation | require_object("Successful-extraction artifact location") |
      if .uriBaseId != "%SRCROOT%" then error("Successful-extraction URI must use %SRCROOT%") else . end |
      .uri | require_nonempty_text("Successful-extraction URI") |
      select(startswith("ManPageCatalog/"))
    else empty end
  else empty end
] | unique |
if length == 0 then error("Swift SARIF contains no located application sources") else .[] end
