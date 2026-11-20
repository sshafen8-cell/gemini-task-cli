# Single App smoke tests

Verified on Gemini Mac 1.147.5.1526, 2026-11-20. These are native App tests using the signed-in App quota, not API simulations. Grant Accessibility to the actual command runner, and use a small existing authorized project directory.

1. From an ordinary, unregistered Gemini instance, attempt `start --worker`: expect `single_app_in_use`, no extra process, no window navigation.
2. Quit that ordinary instance. Start two CLI commands concurrently with different `GEMINI_TASK_STATE_DIR` values. Monitor processes by the exact Gemini executable path. Expect at most one Gemini App process; a concurrent command may return `bridge_busy`. During account startup, `account_unconfirmed` may be retried after loading.
3. Wait for the accepted job and verify its file content in the original directory. Submit from the second state directory after completion: expect the same `worker_pid` and a separately archived job.
4. Follow up the first completed job after the second Task has occupied the window. Expect the first native Task to reopen in the hidden App, the same PID, and the requested output.
5. Submit a competing job while that follow-up is running: expect `worker_busy` with the existing job ID and state directory. No competing prompt should be submitted.
6. Hold the fixed runtime `ui.lock` from another process, then call a UI command from another archive directory: expect `bridge_busy`.
7. Unhide only the verified CLI-managed instance without activating it, then call a worker command: expect it to become hidden and keep the same foreground application. Verify the resulting state, since AppKit's `hide()` return value alone does not prove visibility.
8. Check `history --limit 10`, reject non-positive/non-integer limits, and read the saved answers after `worker-stop`.

Observe foreground activation notifications and sample the foreground PID throughout App operations. In this run the foreground remained Codex. A CLI-managed instance in the foreground is rejected by the code; tests did not intentionally activate Gemini. Account switching and permission grants from Antigravity were not repeated in this run.

The global coordination guarantee applies to updated CLI clients. Other software can still start extra App processes; the worker detects these and refuses to dispatch. Multiple callers share one UI slot; there is no automatic queue or parallel Task execution in one window.
