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

## Default background policy and skill installation

The default mode now uses the hidden worker. Foreground operations require an explicit `--interactive`; omission of `--worker` is no longer an implicit foreground permission.

```bash
python3 tests/test_background_policy.py --bin /absolute/path/to/gemini-task
```

The black-box suite makes no submissions and never opts in to foreground mode. It checks default policy, model/attachment/folder preflight rejection, mode conflicts, strict `--no-navigation`, read-only legacy status/wait, archived answers scoped to the current prompt marker, and rejected legacy follow-up/open/cancel operations. On a signed-in Mac with an ordinary Gemini instance running, all 30 checks passed under a foreground activation monitor; the foreground remained Codex and no Gemini activation appeared.

The actual failing command shape (`start --allow-new-folder --attach ...`, without `--worker`) was repeated against the updated binary previously used by the other chat. It returned `interactive_required` before submission; foreground monitoring again remained Codex. Reading the existing legacy job's status also preserved foreground state.

The local installer was checked in an isolated test directory for shared binary/link targets, both skill copies, backups and preservation of unrelated files. Real installation was then verified through both command aliases and both skill paths. A fresh independent agent's system-provided Available skills list included `gemini-task-cli`; it read the skill and chose the CLI for the request to use Gemini App as a subagent without stealing focus. This verifies discovery in that fresh context, not that an already-running chat has loaded new instructions.

## Unresponsive App and worker recovery (2026-11-22)

An actual CLI-managed Gemini 1.147.5.1526 process was found unresponsive: the window AX query timed out (-25204), CPU use was about one core, and a one-second process sample showed its main thread in a SwiftUI/AttributeGraph accessibility/text update cycle. This is runtime evidence of the observed hang; it does not identify which prior operation triggered it.

`doctor --ui` now distinguishes an AX timeout, a verified main window, and unknown window metadata without activating the App. A process being present or hidden is not a readiness check. A freshly launched process gets a bounded main-window readiness grace period before new Task controls are used. Existing unresponsive processes fail without repeated UI manipulation.

`worker-stop` does not hide first. It verifies shared process ownership, PID/launch time, current account and unfinished-job records. Responsive UI checks inspect all windows for busy/draft/approval state. Without responsive UI and without a registered unfinished job it only asks the owned App to quit normally. Failure returns `worker_stop_failed`; there is no automatic force termination. Unknown window titles are not treated as proof of absence/idle, and the CLI does not automatically terminate based on them.

Observed tests:

- A normal quit request to the original hung process failed and left it running. Its subsequent forced termination was separately and explicitly approved by the user and performed only for that exact registered PID; it is not CLI policy.
- After restart, a Neon Task wrote a new file in an existing authorized original directory and completed. The same Task's follow-up wrote the verified original contents plus a new line. Both used the same hidden PID.
- After a successful normal stop, the final build cold-started a single hidden instance and completed another Neon file-writing task with correct bytes. The initial pre-grace build had failed at startup readiness; that failure was not counted as a submitted job.
- A healthy managed instance was made visible without activation, then `worker-stop` succeeded without first hiding it. Foreground activation traces for all these operations remained Codex.
- The 30 background-policy checks passed both with the hung process and after recovery; two isolated installer tests cover backups and idempotence.
- Installed skill directories contain no historical backup files. Prior skill/binary backups were preserved outside discovery paths with a manifest, and current skills passed validation.

These are bridge smoke tests, not the user's Phase 1 music-transcription task. They do not validate granting the home directory or foreground `--interactive` flows. The CLI still depends on native accessibility for UI operations; a future App hang is reported rather than silently treated as task completion.

An extended native-read check exposed one `worker_stopped` false negative while the same PID was still live and responsive. Managed-process lookup now resolves the saved PID directly, checks the bundle and launch time, and allows one short AppKit refresh retry. Repeated native reads also exposed a transient `history_search_unconfirmed`; a subsequent exact-ID search succeeded. Reads of an already selected Task now reuse it only when its saved native-to-local mapping, displayed local ID, title and Task control all match. Otherwise the conservative search verification remains; unknown search results are not accepted as completion.
