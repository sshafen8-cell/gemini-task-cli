---
name: gemini-task-cli
description: 用本机 gemini-task CLI 调用 Gemini Mac App 的原生 Task。适用于把项目目录里的工作交给 Gemini 后台执行、打开或续聊已有 Task，以及搜索和读取按 Gemini 账号保存的本地档案。
---

# Gemini Task CLI

用已登录的 Gemini Mac App 执行原生 Task，使用 App 账号的额度和目录授权。沿用用户给出的原项目目录。提交之前确认任务目标、可以操作的范围及预期产物。

## 定位 CLI

优先使用 `GEMINI_TASK_BIN` 指定的二进制，其次使用 PATH 上的 `gemini-task`。若两者都不可用，从 CLI 源码仓库按其 README 构建，并使用构建产物的绝对路径。以下示例用 `gemini_task_bin` 保存已核实的可执行文件路径。

```bash
gemini_task_bin="${GEMINI_TASK_BIN:-$(command -v gemini-task || true)}"
test -x "$gemini_task_bin" && "$gemini_task_bin" --help
```

命令通常返回 JSON，`--help` 返回命令说明。需要操作 App 时，用 `doctor` 检查安装、图形桌面、辅助功能授权和当前 `account_id`。后台首次启动需要主 Gemini App 已登录且运行。处理同一个 job 时保持 `GEMINI_TASK_STATE_DIR` 一致。

## 找到目标 Task

- 先用 `history` 或 `history --query '关键词'` 查当前账号的本地档案，再用 `history-read HISTORY_ID` 读旧提示和回复。这两条命令直接读本地记录。
- 本地找不到旧 Task 时，用 `tasks --query '标题或提示词片段'` 在后台查 Gemini App 并导入命中的记录。拿到 `native_conversation_id` 后，可用 `read NATIVE_ID` 读取 App 已加载的正文，或用 `open --worker NATIVE_ID` 在后台打开。对于未登记的原生 ID，可补 `--query` 定位。
- `job_id` 用于查状态、等待和续聊 CLI 派发的工作。定位 Gemini 的原生会话优先用 `native_conversation_id`。`conversation_id` 可能是本机备份 ID，已确认映射后可作为别名使用。
- 本地档案覆盖已归档或导入的记录。App 搜索只返回可见的匹配项。换号后重新读取 `account_id`，并在当前账号范围内选择会话。

## 后台执行

保持前台和主窗口不变时，使用独立的 `--worker`。以下各行是不同动作。新建只选 `run` 或 `start` 中的一种，续聊只选与目标身份对应的命令。

```bash
# 新建并等待
"$gemini_task_bin" run --worker --cwd "$project_dir" \
  --prompt-file "$prompt_file" --result "$relative_output" --timeout 300

# 续聊后台 CLI job
"$gemini_task_bin" follow-up --worker "$job_id" \
  --prompt-file "$prompt_file" --result "$relative_output"

# 续聊 App 原生 Task
"$gemini_task_bin" follow-up --worker "$native_id" --cwd "$project_dir" \
  --prompt-file "$prompt_file" --result "$relative_output"

# 查进度或等待已有 job
"$gemini_task_bin" status "$job_id"
"$gemini_task_bin" wait "$job_id" --timeout 300
```

- `--cwd` 传原项目的绝对路径。`--result` 可重复，用来核验项目内的产物。仅在约定需要文件产物时传它。按原生 ID 续聊会沿用原 Task 已连接的目录，`--cwd` 用于核对和定位产物。
- 需要立即交回 job ID 时，用 `start --worker`，后续单独 `wait`。新建时可按用户要求传 `--model`，未指定则沿用 App 默认。普通 `models` 命令可能切换主窗口。
- 后台需要已经授权的目录。只有允许走普通 App 流程时，才使用首次授权的 `--allow-new-folder` 或文件上传的 `--attach`。遇到 `worker_folder_not_authorized`、`history_search_unavailable`、`worker_in_front` 或 `worker_visible` 时报告具体阻塞，保持当前后台约束。
- 切号时如遇 `account_changed`、`account_unconfirmed` 或 `account_process_mismatch`，等 App 账号就绪后再核对 `account_id` 和目标 job。当前账号找不到旧 ID 时，先确认归属。

## 判断执行结果

- `completed` 表示 Gemini 报告完成且约定的产物已更新。交付前在原目录核验产物内容，或用 `history-read JOB_ID` 读取已保存的回复。
- `submitted`、`running` 或等待超时（退出码 3）时，保留 `job_id` 并查询或继续等待同一单。收到 `submission_unknown` 时，先用返回的 `job_id` 核对原提交，再决定是否需要重试。
- `needs_input` 表示 App 等待处理，`missing_output` 表示 App 已结束但约定文件未通过核验。向调用方说明具体状态与现有产物。
