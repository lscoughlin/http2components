# Bounded server review

On 2026-11-11, the complete merged server runner exceeded a 60-second
process deadline. A separate 45-second diagnostic run used progress output
and a one-second macOS process sample. It reached the connection-age suite.
The sample shows TestH1WebSocketStaysOpenPastAgeAndGrace in Sleep. This is
a timed test, so the short deadline does not establish a deadlock.
The diagnostic process group was stopped. The full runner is not a pass.

The progress output also showed a failure in the factory suite. A focused
run identified stale source paths in TestDefaultsOnlyInCreate after the
role directory move. The fixture paths now use src/server. All 27 factory
tests pass after the correction. The ten TLS context tests also pass in
isolation with OpenSSL 3.

Evidence is in bin/review-server-complete.log,
bin/review-server-progress.log, bin/review-server-stall.sample,
bin/review-server-factory-final.log, and bin/review-server-mtls-context.log.
The separate validation plan includes completion of the full timed server
runner with an appropriate deadline, before load and platform acceptance.
No full-suite or Linux success is claimed here.
