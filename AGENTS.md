# Agent Instructions

## Landing the Plane (Session Completion)

**When ending a work session**, complete the steps below. Work is not complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File follow-up notes** - Capture anything that needs follow-up in the handoff or the issue tracker specified by the user.
2. **Run quality gates** - If code changed, run the relevant tests, linters, or builds.
3. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   git push
   git status  # MUST show "up to date with origin"
   ```
4. **Clean up** - Clear stashes and prune remote branches when appropriate.
5. **Verify** - All intended changes are committed and pushed.
6. **Hand off** - Provide context for the next session.

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds.
- NEVER stop before pushing - that leaves work stranded locally.
- NEVER say "ready to push when you are" - YOU must push.
- If push fails, resolve and retry until it succeeds.
