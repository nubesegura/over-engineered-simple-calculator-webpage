# End-to-end test of the deployed webpage (dev only)

Recorded browser run against the dev site: sign in with a test user, use the calculator, sign out, check that the
session is refused, then collect the BFF logs. Prod is refused by every tool (no test user and no recorded sign-in in prod).

## One-time setup

```
pip install -r scripts/e2e/requirements-e2e.txt
playwright install chromium
```

ffmpeg must be on the PATH for `--record` (Windows screen capture, `recorder.py`).

## Run (from the repository root)

1. Create the test user. It CHANGES AWS (Cognito `admin-create-user`): run it yourself or with the owner's authorization.
   The password is random, written to `.secrets/test-users-dev.json` (git-ignored, mode 600) and never printed.
   ```
   python scripts/e2e/create_test_user.py        # delete later with --delete
   ```
2. Run the browser test (visible Chromium; `--record` also records the screen to `recording.mp4`):
   ```
   python scripts/e2e/web_driver.py --record
   ```
3. Collect the BFF logs and alarm states of the run window (read only):
   ```
   python scripts/e2e/collect_logs.py --run-dir e2e-runs/<run folder>
   ```

## Output (`e2e-runs/<UTC date>-<UTC time>/`, git-ignored)

| File | Content |
| --- | --- |
| `run.log` | one line per step, refused by the secret guard if it carries a password, JWT, long token or account id |
| `results.json` | start and end time, checks, pass/fail |
| `trace.zip` | Playwright trace, redacted after the run (password, JWTs, cookie and authorization values) |
| `*.png`, `recording.mp4` | screenshots and screen recording |
| `logs/lambda-auth-bff.jsonl`, `logs/summary.json` | sanitized BFF log events; counts, ERROR lines, alarm states, checks |

The driver rescans the whole run folder for secrets at the end (check "no secrets in the run folder"); the collector
fails its check "no secrets in logs" if a password or JWT is found in the raw logs. Treat either failure as a finding.

## Real-time (WebSocket) and Live History steps

After sign-in, when AppSync Live History (`EVENTS_REALTIME_DOMAIN`, `EVENTS_HTTP_DOMAIN`, `GRAPHQL_URL`) is configured
on the `dev` page (or `--require-live-history` is given), the driver waits up to 10 seconds for the History section to
display the `Live` status badge (`Live history status: Live`, check `live_history_connected`).

After the REST calculation the driver chooses `Real-time (WebSocket)`, waits for the chip `Connection status: Connected`,
calculates 6 x 7 (expects 42) and 1 / 0 (expects `Result: Cannot divide by zero.`), and—when live history is active—verifies
within 3 seconds (`timeout=3000`) that the History section automatically displays both rows (`6 × 7 = 42` and
`1 ÷ 0 = Cannot divide by zero.`) with a `· websocket` transport subtitle without clicking the `Refresh history` button
(check `live_history_auto_updated`). It then logs out and checks that every WebSocket the page opened is closed (the
socket URL or subprotocol carries auth material, so only counts are logged). The REST calculation stays informational
unless `--require-backend` is given (7.5); the real-time and configured live-history checks always decide the run.
Selectors use the app labels: `Real-time (WebSocket)`, `Connection status: <status>`, `Live`, `Live history status: <status>`,
`×`, `÷`, `Result:`.

Token and subprotocol checks (fail the run if found): the browser console lines are searched for a password, a JWT, a
`token=` query parameter, or an AppSync Events `header-<base64url>` auth subprotocol (check "no token or token= in the
browser console"). The trace is redacted first (`?token=<value>` becomes `<redacted>`, `header-<base64url>` becomes
`header-<redacted>`, and `wss://*.appsync-realtime-api.*` becomes `wss://<redacted-appsync-realtime>`), then the run
folder scan fails on any `token=` query value or `header-<base64url>` subprotocol that is still unmasked (check "no
secrets in the run folder"); the compiled app files stored under `resources/` in the trace are not scanned. Only a
parameter named exactly `token` counts (`csrf_token=` and similar do not). CloudWatch logs are checked by
`collect_logs.py` (JWT and password).

## Notes

- Flutter web draws on a canvas: the driver clicks the accessibility placeholder first so Playwright can see the
  labelled fields and buttons. Chrome DevTools MCP can be used to explore the page; the repeatable run stays this script.
- CloudFront and WAF logging are not enabled in the stack, so only the BFF function logs and its two alarms are collected.
- Offline tests: `pytest scripts/tests/test_e2e_tools.py` (part of the `scripts` CI job; no browser, AWS or network).
