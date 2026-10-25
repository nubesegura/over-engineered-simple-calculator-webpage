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

## Notes

- Flutter web draws on a canvas: the driver clicks the accessibility placeholder first so Playwright can see the
  labelled fields and buttons. Chrome DevTools MCP can be used to explore the page; the repeatable run stays this script.
- CloudFront and WAF logging are not enabled in the stack, so only the BFF function logs and its two alarms are collected.
- Offline tests: `pytest scripts/tests/test_e2e_tools.py` (part of the `scripts` CI job; no browser, AWS or network).
