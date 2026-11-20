# Gemini Task CLI

通过命令行调用已登录的 Gemini Mac App，创建、查询和续聊原生 Task。Gemini 使用 App 账号的额度，可以在原项目目录里读写文件。CLI 将任务状态和已读取的对话按账号归档，并以 JSON 返回给调用方。

## 构建

在安装了 Gemini Mac App 的 macOS 上，用 Swift 工具链编译。

```bash
swiftc -O GeminiTask.swift -o gemini-task
./gemini-task doctor
```

操作 App 需要有登录的图形桌面，并给实际运行命令的终端或 harness 授予 macOS 辅助功能权限。先在 Gemini App 登录一次；后台模式可以在 App 已退出时直接启动它。请从每个 harness 分别运行 `doctor`，一个 harness 的授权不代表其他 harness 已获授权。

## 后台执行和续聊

在原项目目录中执行。后台模式直接使用 Gemini 已授权的目录。

```bash
GEMINI_TASK_BIN="/absolute/path/to/gemini-task"

"$GEMINI_TASK_BIN" run --worker --cwd "$PWD" \
  --prompt '审阅项目中的草稿，将反馈保存到 review.md。' \
  --result review.md --timeout 300
```

- `run` 提交后等待。需要先拿到 job ID 时，用 `start --worker`，再用 `status JOB_ID` 或 `wait JOB_ID`。较长的提示词可用 `--prompt-file FILE`，或用 `--prompt-file -` 从标准输入读入。
- 新建时可用 `--model NAME` 指定 App 中可用的模型。普通 `models` 命令可能切换主窗口。
- 用 `follow-up --worker JOB_ID --prompt TEXT` 续聊 CLI 已经派发的 Task。来源为原生会话时，用 `open --worker NATIVE_ID` 打开，或用 `follow-up --worker NATIVE_ID --cwd DIR --prompt TEXT` 续聊。沿用已有 Task 的目录和上下文。
- `completed` 表示 App 报告完成且指定产物已更新。等待超时返回退出码 3，可继续查询同一个 job。出现 `submission_unknown` 时，先核对已返回的 job ID，避免重复提交。
- 首次目录授权和附件上传使用普通 App 流程。后台模式使用已授权目录。隐藏进程无法确认账号或打开历史搜索时，CLI 返回对应错误。

## 单 App 调度

`--worker` 使用当前 macOS 用户共享的一份后台 Gemini App。进程记录、UI 锁和活动任务记录放在固定的 `~/Library/Application Support/gemini-task/runtime`，不随 `GEMINI_TASK_STATE_DIR` 改变。新版本不使用 `open -n`；不同代理使用不同档案目录，也会复用同一个后台 PID。

- 未运行 Gemini 时，CLI 启动一份隐藏 App；已登记的后台实例会被复用。若是普通方式打开且没有登记的 Gemini，返回 `single_app_in_use`，请在方便时退出它再重试，CLI 会接管后续的隐藏启动。不会另开第二份，也不会接管该窗口。
- `bridge_busy` 表示另一条命令正在短暂操作 UI，可稍后重试。`worker_busy` 表示已有未完成任务，错误中包含原 job ID 和档案目录；先查询或等待该任务。当前没有自动队列，也不在同一个窗口并行派发多个 Task。
- CLI 自己启动的后台实例意外显示时，只要它没有成为前台，就会自动恢复隐藏。正在前台使用 Gemini 时，返回 `worker_in_front`，切走后重试。普通用户窗口不会被自动隐藏。
- 单进程模式由 CLI 管理这一个窗口。它不能同时提供一份供用户自由浏览的主窗口和一份独立隐藏窗口。外部程序手动额外启动 Gemini 时，CLI 返回 `multiple_app_instances`，不会擅自关闭窗口。
- `worker-stop` 只关闭经过 PID、启动时间和所有权核验的 CLI 实例；有未完成任务时拒绝关闭。`doctor` 返回 `worker_policy`、`app_process_count`、`worker_pid` 和 `worker_hidden`，便于调用方核验。

所有 harness 都应更新二进制和 skill；旧版 CLI 不参与新的全局锁。

## 历史档案和账号

```bash
"$GEMINI_TASK_BIN" history --query '项目名或关键词' --limit 10
"$GEMINI_TASK_BIN" history-read HISTORY_ID
"$GEMINI_TASK_BIN" tasks --query '旧任务的标题或提示词片段'
```

- `history` 和 `history-read` 读取当前账号的本地档案。`tasks --query` 在 App 中搜索并归档命中的原生 Task。`read NATIVE_ID` 读取 App 已加载的正文。
- 账号历史的覆盖取决于已归档或导入的 Task。CLI 将 App 查询到的结果标记为 `complete_account_history: false`。
- 默认状态目录是 `~/Library/Application Support/gemini-task`。多个 harness 可共享同一个 `GEMINI_TASK_STATE_DIR`。每个本机 Gemini 登录资料使用自己的档案；后台进程在本机共享，访问时核验当前账号，`doctor` 和 `history` 返回当前资料的 `account_id`。切号时有旧账号未完成任务，会返回 `worker_account_busy`，需切回原账号核对状态。

## 给其他 harness 使用

将构建好的 `gemini-task` 放到目标 harness 的 PATH，或设置 `GEMINI_TASK_BIN` 为其绝对路径。支持 `SKILL.md` 的 harness 可加载仓库里的技能目录。[Gemini Task CLI skill](skills/gemini-task-cli/SKILL.md)

运行 `gemini-task --help` 查看完整命令和参数。
