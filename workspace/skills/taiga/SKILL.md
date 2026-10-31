---
name: taiga
description: >-
  Manage projects, Scrum sprints (milestones), user stories, backlog items, tasks,
  issues, epics, and wiki pages on the self-hosted Taiga server (https://taiga.vitorx86.dev)
  via the Taiga REST API (/api/v1). Use whenever the user asks to inspect, create,
  update, plan, or organize Taiga projects, sprints, user stories, tasks, bugs/issues,
  epics, or wiki documentation, or sync GitHub repositories with Taiga.
---

# Taiga Project Management Skill (`https://taiga.vitorx86.dev`)

This skill provides a zero-dependency CLI tool and REST API runbook for interacting with `vitorecomp`'s self-hosted Taiga instance at `https://taiga.vitorx86.dev`.

## Helper Scripts

1. **General Taiga API CLI**:
   - Global skill script: [`taiga_cli.py`](file:///usr/local/google/home/vieiravitor/.gemini/config/skills/taiga/scripts/taiga_cli.py)
   - Repository copy (`personal-infra`): [`workspace/scripts/taiga_cli.py`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/workspace/scripts/taiga_cli.py)
2. **GitHub -> Taiga Repository Enrollment & Ordering**:
   - [`workspace/scripts/enroll_taiga_projects.py`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/workspace/scripts/enroll_taiga_projects.py)

> [!IMPORTANT]
> - Always run the checked-in CLI scripts (`taiga_cli.py` or `enroll_taiga_projects.py`) via `run_command` rather than inline `python3 -c` socket/HTTP snippets.
> - Authentication is automatic: `taiga_cli.py` checks `TAIGA_AUTH_TOKEN`, `~/.cache/taiga_cli/token.json`, `TAIGA_ADMIN_PASSWORD`, and automatically falls back to reading `TAIGA_ADMIN_PASSWORD` from the `taiga` Cloud Run service in GCP project `compute-bench` (`us-central1`) via `gcloud`.
> - All mutating commands support `--dry-run`.

---

## Common CLI Workflows

Set `CLI=~/.gemini/config/skills/taiga/scripts/taiga_cli.py`:

### 1. Projects

```bash
# List all projects in display order (most recent GitHub commit first)
python3 ~/.gemini/config/skills/taiga/scripts/taiga_cli.py projects list

# Filter projects by name/slug/description
python3 ~/.gemini/config/skills/taiga/scripts/taiga_cli.py projects list --search personal

# Inspect a project's statuses, story point scale, and settings (by name, slug, or ID)
python3 ~/.gemini/config/skills/taiga/scripts/taiga_cli.py projects get personal-infra

# Create or update a project (defaults to Scrum)
python3 ~/.gemini/config/skills/taiga/scripts/taiga_cli.py projects create --name my-repo --template scrum --tags personal,python --dry-run
python3 ~/.gemini/config/skills/taiga/scripts/taiga_cli.py projects update personal-infra --template scrum --tags personal,infra
```

### 2. Scrum Sprints (Milestones)

```bash
# List sprints in a project
python3 ~/.gemini/config/skills/taiga/scripts/taiga_cli.py sprints list personal-infra

# Create a sprint
python3 ~/.gemini/config/skills/taiga/scripts/taiga_cli.py sprints create personal-infra \
  --name "Sprint 1" --start 2026-11-01 --end 2026-11-15

# Close or update a sprint
python3 ~/.gemini/config/skills/taiga/scripts/taiga_cli.py sprints update <sprint_id> --closed
```

### 3. User Stories (Backlog & Sprint Items)

Default Scrum user story statuses: `New`, `Ready`, `In progress`, `Ready for test`, `Done`, `Archived`.
Default story point labels: `?`, `0`, `1/2`, `1`, `2`, `3`, `5`, `8`, `10`, `13`, `20`, `40`.

```bash
# List all user stories in a project (or filter by --sprint backlog / <sprint_name> / --status)
python3 ~/.gemini/config/skills/taiga/scripts/taiga_cli.py stories list personal-infra
python3 ~/.gemini/config/skills/taiga/scripts/taiga_cli.py stories list personal-infra --sprint backlog

# Create a user story in the backlog or assigned to a sprint
python3 ~/.gemini/config/skills/taiga/scripts/taiga_cli.py stories create personal-infra \
  --subject "Automate Cloud SQL backups" \
  --description "Configure automated daily backups and retention in Terraform" \
  --status "Ready" --points "3" --tags terraform,cloud --assign-to-me

# Bulk-create multiple backlog user stories at once
python3 ~/.gemini/config/skills/taiga/scripts/taiga_cli.py stories bulk-create personal-infra \
  --subjects "Story A" "Story B" "Story C"

# Update a user story's status, points, or sprint assignment (use --sprint none for backlog)
python3 ~/.gemini/config/skills/taiga/scripts/taiga_cli.py stories update <story_id> \
  --status "In progress" --points "5" --sprint "Sprint 1"
```

### 4. Tasks (Under User Stories or Standalone)

Default task statuses: `New`, `In progress`, `Ready for test`, `Closed`, `Needs Info`.

```bash
# List tasks in a project (optionally filter by --story <story_id> or --sprint <sprint>)
python3 ~/.gemini/config/skills/taiga/scripts/taiga_cli.py tasks list personal-infra

# Create a task linked to a user story
python3 ~/.gemini/config/skills/taiga/scripts/taiga_cli.py tasks create personal-infra \
  --subject "Write unit tests" --story <story_id> --status "New" --assign-to-me

# Update task status
python3 ~/.gemini/config/skills/taiga/scripts/taiga_cli.py tasks update <task_id> --status "Closed"
```

### 5. Issues & Bugs

Default issue statuses: `New`, `In progress`, `Ready for test`, `Closed`, `Needs Info`, `Rejected`, `Postponed`.
Default types: `Bug`, `Question`, `Enhancement`.
Default priorities: `Low`, `Normal`, `High`.
Default severities: `Wishlist`, `Minor`, `Normal`, `Important`, `Critical`.

```bash
# List issues in a project
python3 ~/.gemini/config/skills/taiga/scripts/taiga_cli.py issues list personal-infra

# Create a bug/issue
python3 ~/.gemini/config/skills/taiga/scripts/taiga_cli.py issues create personal-infra \
  --subject "Fix timeout on cold start" --type Bug --priority High --severity Important --assign-to-me

# Update issue status
python3 ~/.gemini/config/skills/taiga/scripts/taiga_cli.py issues update <issue_id> --status "Closed"
```

### 6. Epics & Wiki Pages

```bash
# Create an epic and link a user story to it
python3 ~/.gemini/config/skills/taiga/scripts/taiga_cli.py epics create personal-infra --subject "Q4 Cloud Reliability"
python3 ~/.gemini/config/skills/taiga/scripts/taiga_cli.py epics link-story <epic_id> --story-id <story_id>

# Create or update a project Wiki page (idempotent)
python3 ~/.gemini/config/skills/taiga/scripts/taiga_cli.py wiki set personal-infra \
  --slug home --content "# Personal Infra Wiki\n\nArchitecture and runbooks."
python3 ~/.gemini/config/skills/taiga/scripts/taiga_cli.py wiki get personal-infra --slug home
```

### 7. Raw REST API Escape Hatch

For any other Taiga REST API v1 endpoint (`/api/v1/...`), use the `raw` subcommand:

```bash
python3 ~/.gemini/config/skills/taiga/scripts/taiga_cli.py raw GET /api/v1/users/me
python3 ~/.gemini/config/skills/taiga/scripts/taiga_cli.py raw POST /api/v1/projects/bulk_update_order \
  --data '[{"project_id": 71, "order": 1}]'
```
