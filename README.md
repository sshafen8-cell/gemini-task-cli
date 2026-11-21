# Gemini Task CLI

通过命令行将任务交给已登录的 Gemini Mac App，创建、查询和续聊原生 Task。Gemini 使用 App 账号的额度，可以在已授权的项目目录里读写文件。CLI 按账号归档任务状态和已读取的对话，以 JSON 返回结果。

## 安装

在安装了 Gemini Mac App 和 Swift 工具链的 macOS 上，从仓库根目录执行：

```bash
python3 scripts/install-local.py
```

也可安装已经编译好的可执行文件，必须传入绝对路径：

```bash
python3 scripts/install-local.py --binary /absolute/path/to/gemini-task
```

安装器将 CLI 放在 `~/.local/share/gemini-task/bin/gemini-task`，把 `~/.local/bin/gemini-task` 和 `~/.local/bin/gemini-task-cli` 链接到它，并在 `~/.codex/skills/gemini-task-cli`、`~/.gemini/config/skills/gemini-task-cli` 安装 skill，两处的 `bin/gemini-task` 都指向同一份 CLI。被替换的文件和这两处技能目录中旧的 `SKILL.md.backup-*`、`bin/gemini-task.backup-*` 会保存在技能发现目录之外的 `~/.local/share/gemini-task/backups/<时间戳>/<原 HOME 相对路径>`；同目录的 `manifest.json` 记录原路径、备份路径及类型，符号链接保留原目标。内容相同的文件和已正确指向的链接不会重复备份，其他文件不受影响。确保 `~/.local/bin` 在 PATH 中，或使用稳定二进制的绝对路径。

安装文件不代表现有活跃会话已经加载新 skill；需要该会话实际读取更新后的 `SKILL.md` 才能确认。旧二进制不会自动更新；所有 harness 都应使用稳定安装入口。也可以手动构建：

```bash
swiftc -O GeminiTask.swift -o gemini-task
./gemini-task doctor
```

操作 App 需要已登录的图形桌面，以及实际运行命令的终端或 harness 的 macOS 辅助功能权限。先在 Gemini App 登录一次；后台模式可以在 App 已退出时启动它。各 harness 的授权需分别核对。

## 后台任务

CLI **默认后台执行**；`--worker` 仍可使用，作为兼容参数。在原项目目录中执行，并使用已授权的目录：

```bash
gemini-task run --cwd "$PWD" \
  --prompt '审阅项目中的草稿，将反馈保存到 review.md。' \
  --result review.md --timeout 300
```

`run` 提交后等待。需要先拿到 job ID 时用 `start`，再用 `status JOB_ID` 或 `wait JOB_ID`。长提示词可用 `--prompt-file FILE`，或用 `--prompt-file -` 从标准输入读取。可按需要用 `--model NAME` 指定模型；不指定则使用 App 默认。委派任务不需要先列出模型。

用 `follow-up JOB_ID --prompt TEXT` 续聊已验证的后台 job。原生 Task 可用 `open NATIVE_ID` 打开，或用 `follow-up NATIVE_ID --cwd DIR --prompt TEXT` 续聊，保留原 Task 目录和上下文。

后台不支持 `models`、`--attach` 或首次授权的 `--allow-new-folder`；这些操作可能激活 Gemini，返回 `interactive_required`。仅当用户明确允许前台交互时，才对具体命令添加 `--interactive`。不要在遇到该错误后自行添加此参数或改用电脑操作工具绕过限制。`--interactive` 与 `--worker`、后台环境设置及 `--no-navigation` 冲突。

旧前台 job 的 `status` 和 `wait` 默认只读观察当前已选会话，不切换窗口；无法确认时保留原状态。默认 `answer` 读取本地存档，缺少已保存回复则返回 `answer_not_archived`。续聊需使用已验证的后台 job 或原生 Task；默认模式不会直接续聊或取消旧前台 job。

`completed` 表示 App 报告完成且约定产物已更新，交付前仍应检查实际内容。等待超时返回退出码 3，可继续查询同一 job。出现 `submission_unknown` 时先核对已返回的 job ID，避免重复提交。

有时 App 已生成最终回复，计划面板仍停在「正在启动」。CLI 也会核对该轮提示和最终回复控件。执行结束后如果指定文件未更新，`wait` 以退出码 1 返回 `execution_state: completed`、`status: missing_output`。用 `answer JOB_ID` 查看该轮存档的回复。

Gemini 连接某个目录后，Task 内部仍可能拒绝访问其中的特定路径。反重力内部 `~/.gemini/antigravity/scratch` 曾出现这种失败。两个 harness 应使用同一个普通项目目录，并以它为 `--cwd`；正式派发前用小文件验证该目录实际可读写。

## 单 App 调度

所有后台调用共享当前 macOS 用户的一份 CLI 管理的 Gemini App。进程记录、UI 锁和活动任务记录位于固定的 `~/Library/Application Support/gemini-task/runtime`，不随 `GEMINI_TASK_STATE_DIR` 改变。不同档案目录仍共用同一个后台 PID。

- 未运行 Gemini 时，CLI 以隐藏方式启动；已登记的后台实例会复用。普通方式打开且未登记的 Gemini 返回 `single_app_in_use`，不会接管它或另开第二份。
- `bridge_busy` 表示另一条命令正在短暂操作 UI，可稍后重试；`worker_busy` 表示已有未完成任务，按返回的 job ID 和档案目录查询或等待。当前没有自动队列。
- CLI 管理的实例意外可见但不在前台时会恢复隐藏；Gemini 已在前台时返回 `worker_in_front`。外部程序额外启动多份时返回 `multiple_app_instances`。
- `worker-stop` 只关闭经过身份和所有权核验的 CLI 实例；有未完成任务时拒绝关闭。恢复流程不要求先隐藏窗口；界面无响应且没有已登记活动 job 时，只请求正常退出，不强制结束进程。正常退出失败返回 `worker_stop_failed`。
- `doctor --ui` 以限时的只读查询报告 `responsive`、`ax_error`、窗口数和主窗口是否存在；`doctor` 本身仍是轻量本地检查。`app_unresponsive` 表示 App 未回答，不能当成任务已完成；`main_window_unavailable` 表示缺少主对话窗口，不能让用户盲点小浮窗。窗口元信息无法核实时，`main_window_present` 为 null，不把未知状态当作空闲，也不自动终止进程。需要恢复时先对已核验的托管实例执行 `worker-stop`，正常退出后再重试后台任务。
- 后台操作依赖 macOS 和 Gemini App 的实际行为；应通过运行时观察确认前台状态。

## 历史档案和账号

```bash
gemini-task history --query '项目名或关键词' --limit 10
gemini-task history-read HISTORY_ID
gemini-task tasks --query '旧任务的标题或提示词片段'
```

`history` 和 `history-read` 读取当前账号的本地档案。`tasks --query` 在 App 中搜索并归档命中的原生 Task；`read NATIVE_ID` 读取 App 已加载的正文。历史覆盖取决于已归档或导入的 Task，App 查询结果标记为 `complete_account_history: false`。

默认状态目录是 `~/Library/Application Support/gemini-task`。每个本机 Gemini 登录资料使用自己的档案；访问后台进程时核验当前账号。切号时若旧账号有未完成任务，会返回 `worker_account_busy`，需切回原账号核对状态。

运行 `gemini-task --help` 查看完整命令和参数。[Gemini Task CLI skill](skills/gemini-task-cli/SKILL.md) 说明给代理使用的约束。
