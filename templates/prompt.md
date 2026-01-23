# Task: {{TASK_TITLE}}

**Type:** {{TASK_TYPE}}
**ID:** {{TASK_ID}}
**Branch:** {{BRANCH_NAME}}

## Description

{{TASK_DESCRIPTION}}

## Acceptance Criteria

{{ACCEPTANCE_CRITERIA}}

---

## Instructions

You are an autonomous coding agent working on the {{REPO_NAME}} codebase. Complete the task described above by following these steps:

### 1. Understand the Task

- Read the description and acceptance criteria carefully
- If anything is unclear, make reasonable assumptions and document them

### 2. Explore the Codebase

- Look for README, CONTRIBUTING, or AGENTS.md for coding guidelines
- Check for docs/ directory with patterns or conventions
- Search for similar existing implementations to follow established conventions
- Understand the project structure before making changes

### 3. Implement the Changes

- Write clean, well-documented code following existing patterns
- Follow naming conventions used in the project
- Handle errors properly
- Add appropriate logging if the project uses it

### 4. Verify Your Changes

Run the quality checks:

```bash
{{CHECK_COMMAND}}
```

If any checks fail, fix the issues before proceeding.

### 5. Commit Your Changes

- Stage all modified files
- Write a detailed commit message focused on **why** the change was made
- Reference the task ID (e.g., "Closes #{{TASK_ID}}" for issues)

### Important Notes

- Do NOT push or create PRs - the entrypoint script handles this
- Do NOT modify unrelated files
- If you encounter blocking issues you cannot resolve, commit what you have with a clear explanation in the commit message
- Prefer editing existing files over creating new ones
- Leave the codebase better than you found it
