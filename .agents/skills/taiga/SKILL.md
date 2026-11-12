---
name: taiga
description: >-
  Manage projects, Scrum sprints (milestones), user stories, backlog items, tasks,
  issues, epics, and wiki pages on the self-hosted Taiga server (https://taiga.vitorx86.dev)
  via the Taiga REST API (/api/v1). Use when the user types "/taiga" or asks to inspect,
  create, update, plan, or organize Taiga projects, sprints, user stories, tasks,
  bugs/issues, epics, or wiki documentation, or sync GitHub repositories with Taiga.
---

# Taiga Project Management Skill (`https://taiga.vitorx86.dev`)

This skill provides a zero-dependency CLI tool and REST API runbook for interacting with `vitorecomp`'s self-hosted Taiga instance at `https://taiga.vitorx86.dev`.

## `/taiga` Slash Command Shorthands

When the user invokes `/taiga ...`, interpret their arguments as follows:
- `/taiga` or `/taiga projects [filter]` -> List projects (`taiga_cli.py projects list [--search <filter>]`).
- `/taiga status <project>` or `/taiga get <project>` -> Show project details, active sprints, and open stories/issues for `<project>`.
- `/taiga stories <project>` -> List user stories in `<project>` (`taiga_cli.py stories list <project>`).
- `/taiga story <project> <subject>` -> Create a user story in `<project>` (`taiga_cli.py stories create <project> --subject "<subject>"`).
- `/taiga sprint <project> <name> <start> <end>` -> Create a sprint in `<project>`.
- `/taiga task <project> <subject>` -> Create a task in `<project>`.
- `/taiga issue <project> <subject>` -> Create an issue/bug in `<project>`.
- `/taiga sync` -> Sync and reorder GitHub repositories from `repo_stats.csv` onto Taiga (`enroll_taiga_projects.py`).
- `/taiga <natural language instruction>` -> Execute the requested Taiga operation using `taiga_cli.py`.

## Helper Scripts

1. **General Taiga API CLI**:
   - Canonical skill script: [`scripts/taiga_cli.py`](./scripts/taiga_cli.py)
   - Workspace wrapper: [`workspace/scripts/taiga_cli.py`](../../../workspace/scripts/taiga_cli.py)
2. **GitHub -> Taiga Repository Enrollment & Ordering**:
   - [`workspace/scripts/enroll_taiga_projects.py`](../../../workspace/scripts/enroll_taiga_projects.py)

> [!IMPORTANT]
> - Always run the checked-in CLI scripts (`taiga_cli.py` or `enroll_taiga_projects.py`) from the shell rather than inline `python3 -c` socket/HTTP snippets.
> - All mutating commands support `--dry-run`; preview before changing anything.
> - Never print, echo, or paste the admin password or auth tokens.

## Configuration (`.env`)

Both scripts read [`.agents/skills/taiga/.env`](./.env.example) (gitignored, mode `0600`) at startup. Create it
from the template once:

```bash
cp .agents/skills/taiga/.env.example .agents/skills/taiga/.env && chmod 600 .agents/skills/taiga/.env
# then fill in TAIGA_ADMIN_PASSWORD (or leave it empty to use the Secret Manager fallback)
```

| Key | Purpose |
| :--- | :--- |
| `TAIGA_URL` | Taiga base URL (default `https://taiga.vitorx86.dev`). |
| `TAIGA_ADMIN_USER` / `TAIGA_ADMIN_EMAIL` | Login id, and an optional second login id. |
| `TAIGA_ADMIN_PASSWORD` / `TAIGA_AUTH_TOKEN` | Credentials (a token skips the login). |
| `TAIGA_SECRET_PROJECT` / `TAIGA_SECRET_NAME` | Secret Manager fallback (`personal-project-514501` / `taiga-admin-password`, read with `gcloud`). |

Precedence: CLI flags > real environment variables > `.env` > Secret Manager. Use `--env-file PATH` (or
`TAIGA_ENV_FILE`) for another file. Auth tokens are cached in `~/.cache/taiga_cli/token.json` (mode `0600`) and
refreshed automatically on a 401. The scripts warn when the `.env` is readable by other users.

---

## Common CLI Workflows

Set `CLI=~/workspace/personal/personal-infra/.agents/skills/taiga/scripts/taiga_cli.py`:

### 1. Projects

```bash
# List all projects in display order (most recent GitHub commit first)
python3 "$CLI" projects list

# Filter projects by name/slug/description
python3 "$CLI" projects list --search personal

# Inspect a project's statuses, story point scale, and settings (by name, slug, or ID)
python3 "$CLI" projects get personal-infra

# Create or update a project (defaults to Scrum)
python3 "$CLI" projects create --name my-repo --template scrum --tags personal,python --dry-run
python3 "$CLI" projects update personal-infra --template scrum --tags personal,infra
```

### 2. Scrum Sprints (Milestones)

```bash
# List sprints in a project
python3 "$CLI" sprints list personal-infra

# Create a sprint
python3 "$CLI" sprints create personal-infra \
  --name "Sprint 1" --start 2026-11-01 --end 2026-11-15

# Close or update a sprint
python3 "$CLI" sprints update <sprint_id> --closed
```

### 3. User Stories (Backlog & Sprint Items)

Default Scrum user story statuses: `New`, `Ready`, `In progress`, `Ready for test`, `Done`, `Archived`.
Default story point labels: `?`, `0`, `1/2`, `1`, `2`, `3`, `5`, `8`, `10`, `13`, `20`, `40`.

```bash
# List all user stories in a project (or filter by --sprint backlog / <sprint_name> / --status)
python3 "$CLI" stories list personal-infra
python3 "$CLI" stories list personal-infra --sprint backlog

# Create a user story in the backlog or assigned to a sprint
python3 "$CLI" stories create personal-infra \
  --subject "Automate restic restore tests" \
  --description "Run backup_stack.py --restore-test weekly and alert on failure" \
  --status "Ready" --points "3" --tags terraform,cloud --assign-to-me

# Bulk-create multiple backlog user stories at once
python3 "$CLI" stories bulk-create personal-infra \
  --subjects "Story A" "Story B" "Story C"

# Update a user story's status, points, or sprint assignment (use --sprint none for backlog)
python3 "$CLI" stories update <story_id> \
  --status "In progress" --points "5" --sprint "Sprint 1"
```

### 4. Tasks (Under User Stories or Standalone)

Default task statuses: `New`, `In progress`, `Ready for test`, `Closed`, `Needs Info`.

```bash
# List tasks in a project (optionally filter by --story <story_id> or --sprint <sprint>)
python3 "$CLI" tasks list personal-infra

# Create a task linked to a user story
python3 "$CLI" tasks create personal-infra \
  --subject "Write unit tests" --story <story_id> --status "New" --assign-to-me

# Update task status
python3 "$CLI" tasks update <task_id> --status "Closed"
```

### 5. Issues & Bugs

Default issue statuses: `New`, `In progress`, `Ready for test`, `Closed`, `Needs Info`, `Rejected`, `Postponed`.
Default types: `Bug`, `Question`, `Enhancement`.
Default priorities: `Low`, `Normal`, `High`.
Default severities: `Wishlist`, `Minor`, `Normal`, `Important`, `Critical`.

```bash
# List issues in a project
python3 "$CLI" issues list personal-infra

# Create a bug/issue
python3 "$CLI" issues create personal-infra \
  --subject "Fix timeout on cold start" --type Bug --priority High --severity Important --assign-to-me

# Update issue status
python3 "$CLI" issues update <issue_id> --status "Closed"
```

### 6. Epics & Wiki Pages

```bash
# Create an epic and link a user story to it
python3 "$CLI" epics create personal-infra --subject "Q4 Cloud Reliability"
python3 "$CLI" epics link-story <epic_id> --story-id <story_id>

# Create or update a project Wiki page (idempotent)
python3 "$CLI" wiki set personal-infra \
  --slug home --content "# Personal Infra Wiki\n\nArchitecture and runbooks."
python3 "$CLI" wiki get personal-infra --slug home
```

### 7. Raw REST API Escape Hatch

For any other Taiga REST API v1 endpoint (`/api/v1/...`), use the `raw` subcommand:

```bash
python3 "$CLI" raw GET /api/v1/users/me
python3 "$CLI" raw POST /api/v1/projects/bulk_update_order \
  --data '[{"project_id": 71, "order": 1}]'
```
