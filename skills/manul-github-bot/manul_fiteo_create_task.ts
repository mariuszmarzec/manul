import { Plugin } from "@opencode/plugin"
import { spawnSync } from "node:child_process"
import os from "node:os"
import path from "node:path"

type ManulFiteoTaskInput = {
  description: string
  parentTaskId?: number | null
  priority?: number
  highestPriorityAsDefault?: boolean
  isToDo?: boolean
  expirationDate?: string | null
}

const manulFiteoCreateTaskTool = {
  name: "manul_fiteo_create_task",
  description:
    "Create a Fiteo Todo task from a Manul task. Root tasks are shared with the configured Mariusz account using EDITOR_AND_VIEWER. Subtasks inherit access from their existing parent and are verified under that parent without adding duplicate direct shares. Use this instead of the raw fiteo_todo_create_task MCP tool, which is blocked in Manul sessions.",
  input: {
    type: "object",
    properties: {
      description: { type: "string", description: "Task description" },
      parentTaskId: {
        anyOf: [{ type: "integer", minimum: 1 }, { type: "null" }],
        description: "Parent task ID for a subtask, or null for a root task",
      },
      priority: { type: "integer", description: "Optional Todo priority" },
      highestPriorityAsDefault: { type: "boolean" },
      isToDo: { type: "boolean" },
      expirationDate: {
        anyOf: [{ type: "string" }, { type: "null" }],
        description: "Optional local date-time in yyyy-MM-dd'T'HH:mm:ss format",
      },
    },
    required: ["description"],
    additionalProperties: false,
  },
  async execute(input: ManulFiteoTaskInput) {
    const args = input
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
      "parentTaskId", "priority", "highestPriorityAsDefault", "isToDo", "expirationDate",
    ] as const) {
      const value = args[key]
      if (value !== undefined) task[key] = value
    }
    const result = spawnSync("python3", [script, "--task-json", JSON.stringify(task)], {
      encoding: "utf8",
      timeout: 45000,
      env: process.env,
    })
    if (result.error) throw new Error("Manul Todo task creation helper could not start")
    if (result.status !== 0) {
      const detail = (result.stderr || "Fiteo task creation or access verification failed").trim()
      throw new Error(detail.slice(0, 600))
    }
    return { content: result.stdout.trim() }
  },
}

export default Plugin.define({
  id: "manul.fiteo-create-task",
  async setup(ctx) {
    await ctx.tool.transform((editor) => {
      editor.add(manulFiteoCreateTaskTool)
    })
  },
})
