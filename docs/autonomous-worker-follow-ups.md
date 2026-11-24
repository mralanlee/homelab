# Autonomous Worker Follow-Up Flow

## Problem Statement

When Lace (the autonomous worker) creates a PR and marks a job as done, the session ends. However, if the PR fails status checks (linting, tests, etc.), there's no mechanism to automatically re-engage Lace to fix the issues.

### Current Flow (Problematic)

1. User requests work via Slack
2. Lace creates a ticket and delegates it to itself
3. Lace creates a PR and pushes code
4. Lace marks the job as "done" and session ends
5. **Problem**: If PR fails status checks, Lace can't be notified
6. User tries to reply in Slack thread → fails (session ended)
7. User posts comment on Linear → creates NEW job/session
8. **Result**: Duplicate tracking, effort not properly measured per ticket

### Example Case: RC-534

- Lace created PR #519 for Mistral OCR retry logic
- PR failed `ruff format --check` with 2 files needing formatting
- User @alan tried to notify Lace in Slack → couldn't reply (session ended)
- User commented on Linear → triggered NEW job instead of continuing work

## Core Issues

### 1. Session Termination Too Early

Lace marks work as "done" after pushing code, but before CI checks complete. A PR isn't truly complete until:
- All status checks pass
- Code is reviewed and approved
- Changes are merged or explicitly closed

### 2. No Re-Engagement Path

When status checks fail, there's no automatic way to re-engage the same Lace session. The workflow should support:
- GitHub check failure → notify Lace
- Slack follow-up → same session continues
- Linear comment → same session continues (not new job)

### 3. Job vs Ticket Tracking Confusion

Creating a new job for follow-up work inflates metrics:
- **Wrong**: Multiple jobs per ticket (original + follow-ups)
- **Right**: One ticket = one unit of work measurement, regardless of iterations

## Proposed Solutions

### Solution 1: GitHub Webhook Integration (Recommended)

Add a GitHub webhook that notifies Lace when status checks fail on its PRs.

**Flow:**
```
PR created by Lace
  ↓
CI runs checks
  ↓
Check fails ─→ Webhook to Lace API
  ↓
Lace resumes SAME session
  ↓
Fixes issues, pushes again
  ↓
Marks done only when checks pass
```

**Implementation:**
- Add webhook endpoint to Lace API: `POST /webhook/github/check-failure`
- Webhook payload includes PR number, repo, failure details
- Lace looks up session by ticket ID (from PR branch name)
- Resume session with context: "Your PR failed checks: {details}"

**Benefits:**
- Automatic re-engagement
- No user intervention needed for simple fixes (formatting, linting)
- Proper session continuity

### Solution 2: Persistent Slack Thread Binding

Keep the Slack thread "alive" until the ticket moves to Done/Merged.

**Flow:**
```
User posts in Slack thread
  ↓
Check if thread has associated ticket
  ↓
Resume existing session (don't create new job)
  ↓
Continue work on same branch/PR
```

**Implementation:**
- Store mapping: `slack_thread_id → ticket_id → session_id`
- When user replies in thread, look up existing session
- If session exists, resume it (don't create new job)
- Mark thread as "inactive" only when ticket is closed

**Benefits:**
- Intuitive UX (reply in same thread)
- No duplicate jobs
- User can provide additional context

### Solution 3: Linear Comment Smart Routing

When user comments on Linear issue delegated to Lace, check for active session before creating new job.

**Flow:**
```
User comments on Linear issue
  ↓
Check if issue has delegate=lace AND active PR
  ↓
If yes: Resume existing session
If no: Create new job
```

**Implementation:**
- Before creating job from Linear comment, query:
  - Is delegate=lace?
  - Is there an open PR linked?
  - Is the PR in a failed state?
- If all yes → resume session
- Otherwise → new job

**Benefits:**
- Works for Linear-native workflow
- Prevents duplicate jobs
- Still supports new work when appropriate

### Solution 4: "Done" Criteria Gate

Change Lace's definition of "done" to include passing checks.

**Flow:**
```
Lace pushes code
  ↓
Poll PR status checks (with timeout)
  ↓
All pass? → Mark done, end session
Any fail? → Fix issues, retry
Timeout? → Mark "blocked", notify user
```

**Implementation:**
- After `gh pr create`, add status check polling:
  ```bash
  gh pr checks $PR_NUMBER --watch --interval 30 --fail-fast
  ```
- If checks fail, parse failure and attempt fix
- Only mark job complete when checks pass
- If can't fix after N attempts, mark blocked and notify user

**Benefits:**
- Self-healing for common issues
- True "done" state
- Fewer interrupted workflows

## Recommended Implementation Plan

### Phase 1: Quick Win (Week 1)
Implement **Solution 4** - update Lace's "done" criteria to wait for passing checks.

**Changes:**
- Modify job completion logic to poll PR checks
- Add retry logic for auto-fixable failures (formatting, imports)
- Only mark complete when checks pass or manual intervention needed

### Phase 2: Slack Thread Persistence (Week 2-3)
Implement **Solution 2** - keep Slack threads bound to tickets.

**Changes:**
- Store thread → ticket mapping
- Update Slack handler to resume sessions
- Add session state management

### Phase 3: GitHub Webhook (Week 4-6)
Implement **Solution 1** - proactive check failure handling.

**Changes:**
- Add webhook endpoint
- Integrate with GitHub Apps
- Auto-resume on failures

### Phase 4: Linear Smart Routing (Week 6-8)
Implement **Solution 3** - intelligent Linear comment handling.

**Changes:**
- Pre-check before job creation
- Session resume logic
- Context preservation

## Success Metrics

After implementation, we should see:

1. **Fewer abandoned PRs**: PRs created by Lace should merge or close explicitly, not sit with failed checks
2. **Single job per ticket**: Each ticket should map to one job/session, even with multiple iterations
3. **Lower user intervention**: Lace should self-heal common issues (formatting, linting)
4. **Clear blocking**: When Lace can't proceed, it should explicitly mark why and hand off to user

## Configuration

Add to `.lace/config.yml`:

```yaml
autonomous_worker:
  completion_criteria:
    require_passing_checks: true
    check_timeout_minutes: 10
    auto_fix_attempts: 3
    
  session_persistence:
    slack_thread_ttl_hours: 72  # Keep thread alive 3 days
    resume_on_comment: true
    
  webhooks:
    github_check_failures: true
    linear_comments: true
    
  self_healing:
    enabled_fixes:
      - ruff_format
      - ruff_lint
      - mypy_imports
      - prettier
```

## Related Issues

- RC-534: Original Mistral OCR formatting issue
- [Future] GitHub webhook integration epic
- [Future] Lace session management improvements
