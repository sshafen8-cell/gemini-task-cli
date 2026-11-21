---
name: gemini-task-cli
description: 当用户要求 Gemini App（Mac 桌面版）执行任务或充当子代理时使用。通过 gemini-task CLI 后台新建、查询和续聊原生 Task，并搜索和读取本地档案。
---

# Gemini Task CLI

只读取当前技能目录的 `SKILL.md`；不要把备份、仓库测试代码或旧探针当作操作指引。使用下述稳定 CLI 入口。

用户要求 Gemini App 执行任务或充当子代理时，使用本 CLI 操作已登录的 Gemini Mac App 原生 Task；调用方可以是 Codex、反重力或其他 harness。默认走 CLI 后台，不先用电脑操作工具点击 Gemini，也不为委派任务先打开模型列表。App 使用其账号额度和已授权目录；任务应沿用用户给出的原项目目录，并明确目标、可操作范围和预期产物。

## 定位 CLI

优先使用 `GEMINI_TASK_BIN` 指定的可执行文件，否则使用稳定安装路径，再使用 PATH 上的 `gemini-task`。安装器将两种入口指向同一份稳定二进制。不要使用项目目录中留存的旧版探针或旧二进制；无法找到已更新的 CLI 时报告问题。

```bash
# skill 的 bin/gemini-task 也指向以下稳定安装路径。
if [ -n "${GEMINI_TASK_BIN:-}" ]; then
  gemini_task_bin="$GEMINI_TASK_BIN"
elif [ -x "$HOME/.local/share/gemini-task/bin/gemini-task" ]; then
  gemini_task_bin="$HOME/.local/share/gemini-task/bin/gemini-task"
else
  gemini_task_bin="$(command -v gemini-task || true)"
fi
test -x "$gemini_task_bin" && "$gemini_task_bin" --help
```

命令通常返回 JSON，`--help` 返回说明。需要操作 App 时，用 `doctor` 检查安装、辅助功能授权和当前 `account_id`。每个运行命令的 harness 的辅助功能授权分别核对。通常使用默认状态目录以共享本地 history；并发不需要另建状态目录。确需分开档案时，处理同一个 job 保持 `GEMINI_TASK_STATE_DIR` 一致。

## 后台执行

CLI 默认后台执行；`--worker` 保留为兼容参数，不必添加。所有 harness 共用一个 CLI 管理的隐藏 Gemini App；进程记录和 UI 锁独立于 `GEMINI_TASK_STATE_DIR`。以下命令是不同动作，新建只选 `run` 或 `start` 中的一种。

```bash
# 新建并等待；需要立即拿到 job ID 时改用 start，再单独 wait
"$gemini_task_bin" run --cwd "$project_dir" \
  --prompt-file "$prompt_file" --result "$relative_output" --timeout 300

# 续聊已验证的后台 CLI job
"$gemini_task_bin" follow-up "$job_id" \
  --prompt-file "$prompt_file" --result "$relative_output"

# 续聊已验证的 App 原生 Task
"$gemini_task_bin" follow-up "$native_id" --cwd "$project_dir" \
  --prompt-file "$prompt_file" --result "$relative_output"

"$gemini_task_bin" status "$job_id"
"$gemini_task_bin" wait "$job_id" --timeout 300
```

`--cwd` 传原项目绝对路径。仅在约定需要文件产物时传 `--result`，可重复传入；原生 Task 的 `--cwd` 用于核对已连接目录和定位产物。用户指定模型时可用 `--model NAME`，未指定则使用 App 默认。不要为普通委派先执行 `models`。

后台只能使用 App 已授权的目录。`models`、`--attach` 和首次授权的 `--allow-new-folder` 需要前台；默认模式会返回 `interactive_required`。**不得自行追加 `--interactive`，也不得切换为电脑操作工具绕过此限制。**只有用户明确允许 Gemini 前台交互后，才可对具体命令使用 `--interactive`；否则报告阻塞及原因。`--interactive` 与 `--worker`、后台环境设置及 `--no-navigation` 冲突。

连接目录并不证明 Task 运行环境能读写其中的每个路径。若 Gemini 回复无法访问反重力内部的 `~/.gemini/antigravity/scratch`，向调用方返回具体路径和原回复。让两个 harness 使用同一个普通项目目录，优先从该目录启动项目，已有项目的迁移需保留输入与产物并更新路径引用。以项目目录为 `--cwd`，先做小规模读写确认；扩大到主目录或给内部目录套软链接不能作为权限验证。

`single_app_in_use` 表示 Gemini 以普通方式运行且未登记为 CLI 后台实例；不要接管、隐藏或另开它。`multiple_app_instances` 表示存在多份 App；`worker_in_front` 表示 Gemini 已在前台。向用户说明具体状态，在适合的时机处理后重试。`bridge_busy` 是短暂 UI 互斥；`worker_busy` 表示未完成任务占用共享实例，按返回的 job ID 和状态目录查询或等待，不用其他目录绕过占用。后台账号不一致、目录未授权、历史搜索不可用或辅助功能未授权时，报告错误并保持后台约束。

遇到 `control_unavailable`、`app_unresponsive` 或窗口异常，先运行 `doctor --ui`，区分无响应与缺主窗口。`worker-stop` 不要求实例先隐藏，仍只正常退出已核验且没有活动 job 的托管实例；退出失败报告结果，不把点开小浮窗当作已验证的修复，也不自动强杀。

## 找到目标 Task 和旧任务

- 先用 `history --query '关键词' --limit 10` 和 `history-read HISTORY_ID` 读取当前账号本地档案。档案覆盖已保存或导入的记录。
- 本地找不到时用 `tasks --query '标题或提示词片段'` 后台查询 App。取得 `native_conversation_id` 后，可用 `read NATIVE_ID` 读取 App 已加载正文，或 `open NATIVE_ID` 后台打开。未登记的原生 ID 可补 `--query`。App 搜索只返回可见匹配项。
- `job_id` 用于查询和续聊 CLI 派发的任务；定位原生会话优先用已核验的 `native_conversation_id`。换号后重新检查 `account_id` 和任务归属。
- 旧前台 job 的 `status`、`wait` 在默认模式下仅可只读观察当前已选会话；不会打开其他会话，不能确认时保持原状态。默认 `answer` 只读取已保存的回复；没有存档时报告 `answer_not_archived`，可查本地 history 或已核验的原生 Task。旧前台 job 的续聊和取消不能直接操作前台；续聊须使用经过核验的后台 job 或原生 Task 身份，不能猜测映射。不能安全取消时报告阻塞。

## 判断执行结果

没有返回 `job_id` 的派发错误不等于任务已发出，不能宣称 Gemini 正在执行；保留错误原文再诊断。

- `completed` 表示 App 报告完成且约定产物已更新；交付前检查原目录中的实际内容。
- `submitted`、`running` 或等待超时（退出码 3）时保留 `job_id`，查询或继续等待同一单。`submission_unknown` 时先核对原提交，避免重复派发。
- `needs_input` 表示 App 等待处理。`execution_state: completed` 和 `status: missing_output` 表示 App 已结束，但约定文件未通过核验。`wait` 返回退出码 1，此时应读 `answer JOB_ID` 或 `history-read JOB_ID` 诊断具体阻塞，结束对该次执行的等待。
