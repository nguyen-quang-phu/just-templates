# Lumin frontend — Linear ticket automation
# Part of the remote template. Imported by the fetched `remote.just`.

# Move a Linear card to a workflow state (default "In Progress").
# Resolves the issue + its team, finds the matching state, and updates it.
# Usage:
#   just linear-move 820
#   just linear-move WO-820 "In Review"
#   just linear-move 820 "In Progress" team="WO"
linear-move card state="In Progress" team="WO":
    #!/usr/bin/env bash
    set -euo pipefail
    : "${LINEAR_API_KEY:?LINEAR_API_KEY is required}"

    card="{{card}}"
    team="{{team}}"
    target_state="{{state}}"

    if [[ "$card" =~ ^[0-9]+$ ]]; then
        identifier="${team}-${card}"
    else
        identifier="$card"
    fi

    # 1. Resolve the issue (id, team, assignee) and the current user in one query
    query="$(jq -cn --arg id "$identifier" '{
      query: "query Issue($id: String!) { viewer { id } issue(id: $id) { id identifier team { id } assignee { id } } }",
      variables: {id: $id}
    }')"

    resp="$(curl -s -X POST https://api.linear.app/graphql \
      -H "Content-Type: application/json" \
      -H "Authorization: ${LINEAR_API_KEY}" \
      -d "$query")"

    issue_uuid="$(echo "$resp" | jq -r '.data.issue.id // empty')"
    linear_id="$(echo "$resp" | jq -r '.data.issue.identifier // empty')"
    team_uuid="$(echo "$resp" | jq -r '.data.issue.team.id // empty')"
    assignee_uuid="$(echo "$resp" | jq -r '.data.issue.assignee.id // empty')"
    viewer_uuid="$(echo "$resp" | jq -r '.data.viewer.id // empty')"

    if [[ -z "$issue_uuid" || -z "$team_uuid" ]]; then
        msg="$(echo "$resp" | jq -r '.errors[0].message // empty')"
        echo "❌ Could not resolve Linear issue: ${identifier}"
        [[ -n "$msg" ]] && echo "   ${msg}"
        exit 1
    fi

    # Only move cards assigned to me — skip everyone else's.
    if [[ -z "$assignee_uuid" || "$assignee_uuid" != "$viewer_uuid" ]]; then
        echo "⏭  ${linear_id} is not assigned to you — skipping status update."
        exit 0
    fi

    echo "🔄 Moving ${linear_id} to ${target_state}..."

    # 2. Find the target state for this team
    states_query="$(jq -cn --arg teamId "$team_uuid" '{
      query: "query States($teamId: ID!) { workflowStates(filter: { team: { id: { eq: $teamId } } }) { nodes { id name type } } }",
      variables: {teamId: $teamId}
    }')"

    states_resp="$(curl -s -X POST https://api.linear.app/graphql \
      -H "Content-Type: application/json" \
      -H "Authorization: ${LINEAR_API_KEY}" \
      -d "$states_query")"

    # Prefer an exact name match; otherwise (for "In Progress") fall back to the first "started" state.
    state_id="$(echo "$states_resp" | jq -r --arg name "$target_state" '
      .data.workflowStates.nodes as $nodes
      | ( [$nodes[] | select(.name == $name)]
          + (if ($name | ascii_downcase) == "in progress"
             then [$nodes[] | select(.type == "started")]
             else [] end) )
      | .[0].id // empty
    ')"

    if [[ -z "$state_id" ]]; then
        echo "⚠️  No \"${target_state}\" state found for this team — skipping status update."
        exit 0
    fi

    # 3. Update the issue
    update_query="$(jq -cn --arg id "$issue_uuid" --arg stateId "$state_id" '{
      query: "mutation Update($id: String!, $stateId: String!) { issueUpdate(id: $id, input: { stateId: $stateId }) { success } }",
      variables: {id: $id, stateId: $stateId}
    }')"

    update_resp="$(curl -s -X POST https://api.linear.app/graphql \
      -H "Content-Type: application/json" \
      -H "Authorization: ${LINEAR_API_KEY}" \
      -d "$update_query")"

    if [[ "$(echo "$update_resp" | jq -r '.data.issueUpdate.success // false')" == "true" ]]; then
        echo "✅ ${linear_id} moved to ${target_state}"
    else
        echo "⚠️  Failed to update ${linear_id}: $(echo "$update_resp" | jq -r '.errors[0].message // "unknown error"')"
    fi

# Fetch a Linear issue as compact JSON: { identifier, title, description }.
# Errors go to stderr so stdout stays clean for `$(just linear-issue ...)`.
# Usage:
#   just linear-issue 820
#   just linear-issue WO-820
linear-issue card team="WO":
    #!/usr/bin/env bash
    set -euo pipefail
    : "${LINEAR_API_KEY:?LINEAR_API_KEY is required}"

    card="{{card}}"
    team="{{team}}"

    if [[ "$card" =~ ^[0-9]+$ ]]; then
        identifier="${team}-${card}"
    else
        identifier="$card"
    fi

    query="$(jq -cn --arg id "$identifier" '{
      query: "query Issue($id: String!) { issue(id: $id) { identifier title description } }",
      variables: {id: $id}
    }')"

    resp="$(curl -s -X POST https://api.linear.app/graphql \
      -H "Content-Type: application/json" \
      -H "Authorization: ${LINEAR_API_KEY}" \
      -d "$query")"

    issue="$(echo "$resp" | jq -c '.data.issue // empty')"

    if [[ -z "$issue" ]]; then
        msg="$(echo "$resp" | jq -r '.errors[0].message // empty')"
        echo "❌ Could not find Linear issue: ${identifier}" >&2
        [[ -n "$msg" ]] && echo "   ${msg}" >&2
        exit 1
    fi

    echo "$issue"

# Implement a Linear ticket end-to-end with claude. Stages changed files; does NOT commit/push.
# Usage:
#   just implement-task 820
#   just implement-task WO-820
implement-task card team="WO":
    #!/usr/bin/env bash
    set -euo pipefail

    issue="$(just linear-issue "{{card}}" "{{team}}")"
    linear_id="$(echo "$issue" | jq -r '.identifier')"
    title="$(echo "$issue" | jq -r '.title')"
    description="$(echo "$issue" | jq -r '.description // ""')"

    prompt="$(cat <<EOF
    You are implementing a Linear task in the Lumin platform monorepo.

    Ticket: ${linear_id} — ${title}

    Description:
    ${description}

    Instructions:
    - Implement the task end-to-end, following existing patterns in the touched app/package.
    - Follow the repo CLAUDE.md / AGENTS.md conventions (run gitnexus impact analysis before editing symbols; lint with biome where applicable).
    - Stage ONLY the files you changed for this task (git add <paths>). Never stage .env*, .env.keys, or unrelated lock files.
    - Do NOT commit, push, or open a PR — those are handled by the next steps.
    - Do NOT ask for confirmation. Just implement.
    EOF
    )"
    echo "🤖 Running claude to implement ${linear_id}..."
    claude -p --dangerously-skip-permissions --output-format text "$prompt"

# Full Linear task flow — thin orchestrator over independent step recipes:
#   linear-issue → create-branch → implement-task → create-commit → create-pr → linear-move
# Fully autonomous (no prompts).
# Usage:
#   just linear-task 820
#   just linear-task WO-820
#   just linear-task 820 base="develop-opt"
linear-task card base="develop-opt" team="WO":
    #!/usr/bin/env bash
    set -euo pipefail

    # Resolve ticket once for logging + the commit message hint
    issue="$(just linear-issue "{{card}}" "{{team}}")"
    linear_id="$(echo "$issue" | jq -r '.identifier')"
    title="$(echo "$issue" | jq -r '.title')"
    echo "🎫 ${linear_id} — ${title}"

    # 1. Branch from base (create-branch uses Linear's suggested branchName)
    just create-branch "{{card}}" "{{base}}" "feature/" "{{team}}"

    # 2. Implement the task with claude (stages changed files)
    just implement-task "{{card}}" "{{team}}"

    # 3. Commit the staged changes (follows the commit skill convention)
    just create-commit "${linear_id}: ${title}"

    # 4. Push + open/update the PR against base
    just create-pr "{{base}}"

    # 5. Move the Linear card to "In Progress"
    just linear-move "{{card}}" "In Progress" "{{team}}"
