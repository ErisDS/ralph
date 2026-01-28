<!-- TEMPLATE_DOCS_START -->
# Ralph Once Prompt Template

This template is used by `ralph-once.sh`. You can override it per project by creating `.ralph/prompt-once.md`.

## Placeholders

These placeholders are replaced at runtime:

- `{{TASK_CONTEXT}}` - Task list context (issues or PRD)
- `{{PROGRESS_HEADER}}` - Section title (`Progress So Far` or `Recent Commits`)
- `{{PROGRESS}}` - `progress.txt` (PRD mode) or last 10 commit messages (GitHub mode)
- `{{SECTION_CHOOSE}}` - Task selection instructions
- `{{SECTION_IMPLEMENT}}` - Implementation and feedback loop guidance
- `{{SECTION_DONE}}` - Definition of Done checklist
- `{{SECTION_DELIVER}}` - Delivery instructions (commit/PR behavior)
- `{{SECTION_REVIEW_BLOCK}}` - Optional review loop (Copilot review), includes trailing separator
- `{{COMPLETION_MESSAGE}}` - Final completion instruction
- `{{IMPORTANT_MESSAGE}}` - Final “only one task” reminder

## Notes

- Any content between `<!-- TEMPLATE_DOCS_START -->` and `<!-- TEMPLATE_DOCS_END -->` is stripped before sending the prompt to the agent.
- Keep the placeholder tokens exactly as shown.

<!-- TEMPLATE_DOCS_END -->

# Task Assignment

{{TASK_CONTEXT}}

---

{{PROGRESS_HEADER}}

```
{{PROGRESS}}
```

---

{{SECTION_CHOOSE}}

---

{{SECTION_IMPLEMENT}}

---

{{SECTION_DONE}}

---

{{SECTION_DELIVER}}

---

{{SECTION_REVIEW_BLOCK}}
{{COMPLETION_MESSAGE}}

{{IMPORTANT_MESSAGE}}
