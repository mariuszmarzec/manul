import { tool } from "@opencode-ai/plugin"
import { spawnSync } from "node:child_process"
import os from "node:os"
import path from "node:path"

export default tool({
  description:
    "Create a Fiteo Todo task from a Manul task. Root tasks are shared with the configured Mariusz account using EDITOR_AND_VIEWER. Subtasks inherit access from their existing parent and are verified under that parent without adding duplicate direct shares. Use this instead of the raw fiteo_todo_create_task MCP tool, which is blocked in Manul sessions.",
  args: {
    description: tool.schema.string().describe("Task description"),
    parentTaskId: tool.schema.number().int().positive().nullable().optional().describe("Parent task ID for a subtask, or null for a root task"),
    priority: tool.schema.number().int().optional().describe("Optional Todo priority"),
    highestPriorityAsDefault: tool.schema.boolean().optional(),
    isToDo: tool.schema.boolean().optional(),
    expirationDate: tool.schema.string().nullable().optional().describe("Optional local date-time in yyyy-MM-dd'T'HH:mm:ss format"),
  },
  async execute(args) {
    if (!process.env.MANUL_TASK_WORKSPACE_ROOT) {
      throw new Error("This tool is available only inside a Manul task execution")
    }
    if (!process.env.FITEO_MANUL_PAT) {
      throw new Error("FITEO_MANUL_PAT is missing; refusing to use the operator's Fiteo PAT")
    }
    if (args.parentTaskId == null && !process.env.FITEO_MANUL_SHARE_USER_ID) {
      throw new Error("FITEO_MANUL_SHARE_USER_ID is missing; root-task creation requires a direct share")
    }

    const canonicalDir =
      process.env.MANUL_CANONICAL_DIR ??
      path.join(os.homedir(), ".manul-repo", "skills", "manul-github-bot")
    const script = path.join(canonicalDir, "todo-remote-create-task.py")
    const task: Record<string, unknown> = { description: args.description }
    for (const key of [
      "parentTaskId",
      "priority",
      "highestPriorityAsDefault",
      "isToDo",
      "expirationDate",
    ] as const) {
      const value = args[key]
      if (value !== undefined) task[key] = value
    }

    const result = spawnSync(
      "python3",
      [script, "--task-json", JSON.stringify(task)],
      {
        encoding: "utf8",
        timeout: 45000,
        env: process.env,
      },
    )
    if (result.error) {
      throw new Error("Manul Todo task creation helper could not start")
    }
    if (result.status !== 0) {
      const detail = (result.stderr || "Fiteo task creation or share verification failed").trim()
      throw new Error(detail.slice(0, 600))
    }
    return result.stdout.trim()
  },
})
