<!-- TEMPLATE_DOCS_START -->
# Ralph Once Prompt Template

This template is used by `ralph-once.sh`. Override it per project by creating `.ralph/prompt-once.md`.

## Placeholders

These placeholders are replaced at runtime:

### Required (always replaced)
- `{{TASK_CONTEXT}}` - The task list (GitHub issues JSON or PRD content)
- `{{TASK_ITEM}}` - Either "task" (PRD mode) or "issue" (GitHub mode)
- `{{PROGRESS_HEADER}}` - Section title: "Progress So Far" or "Recent Commits"
- `{{PROGRESS}}` - Content of progress.txt (PRD) or last 10 commits (GitHub)

### Conditional (may be empty)
- `{{SPECIFIC_TASK_INSTRUCTION}}` - When --task is used, instruction to work on that specific task
- `{{PROGRESS_CHECKLIST_ITEM}}` - Mode-specific progress tracking checklist item
- `{{PRE_COMMIT_EXTRA_ITEM}}` - PRD-only: checklist item to update PRD file
- `{{DELIVER_STEPS}}` - Delivery instructions based on commit mode (pr/main/commit/branch/none)
- `{{SECTION_REVIEW}}` - Code review section (only when --copilot is used)

## Notes

- This documentation block (between the HTML comment markers) is stripped at runtime.
- Edit the sections below to customize how the agent approaches implementation.
- Keep placeholder tokens exactly as shown.

<!-- TEMPLATE_DOCS_END -->

# Task Assignment

{{TASK_CONTEXT}}

---

{{PROGRESS_HEADER}}

```
{{PROGRESS}}
```

---

## 1. Choose the {{TASK_ITEM}}

{{SPECIFIC_TASK_INSTRUCTION}}Review the available {{TASK_ITEM}}s and recent activity, then select ONE to work on:
- Pick the next best {{TASK_ITEM}} to work on, prioritising as you see fit
- Fall back to the lowest-numbered {{TASK_ITEM}} if priority isn't clear

---

## 2. Implement the {{TASK_ITEM}}

Work through the {{TASK_ITEM}} systematically, using ALL available feedback loops to ensure code works as intended and passes all checks.

### Available Feedback Loops
Use these to verify your changes are working:
- **Automated tests**: Run the test suite frequently as you make changes
- **Linter/Type checker**: Check for code quality issues and type errors  
- **Manual testing**: Test the actual behavior in a browser/terminal/REPL
- **Build**: Ensure the project compiles/builds without errors
- **AGENTS.md**: Check for project-specific standards, commands, and guidelines

### Implementation Approach
1. Understand the requirements fully before writing code
2. Make incremental changes, testing after each significant change
3. If tests exist, run them early and often
4. If no tests exist for your changes, consider adding them
5. Verify the fix/feature works manually, not just that tests pass
6. Keep iterating until you meet the Definition of Done

---

## 3. Definition of Done

You are ONLY done when ALL of the following are true:
- [ ] All automated tests pass
- [ ] Linter/type checks pass (if available)
- [ ] You have manually verified the change works as intended
- [ ] Code follows project standards (check AGENTS.md)
{{PROGRESS_CHECKLIST_ITEM}}
- [ ] If there are deployments, wait for them to succeed and re-verify your changes work
{{PRE_COMMIT_EXTRA_ITEM}}

---

## 4. Deliver

ONLY after meeting ALL criteria in 'Definition of Done':

{{DELIVER_STEPS}}

---

{{SECTION_REVIEW}}
When complete, output: <promise>COMPLETE</promise>

**IMPORTANT**: Only work on ONE {{TASK_ITEM}}.
