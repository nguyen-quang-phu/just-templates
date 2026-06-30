# Lumin frontend — PR review & resolve-comments workflow
# Part of the remote template. Imported by the fetched `remote.just`.

# Review a GitHub PR and post inline comments via claude
# Usage:
#   just review-pr 1234
#   just review-pr https://github.com/<org>/<repo>/pull/1234
#   just review-pr 1234 dry_run=true
#   just review-pr 1234 event=APPROVE
review-pr pr event="COMMENT" dry_run="false" extra="":
    #!/usr/bin/env bash
    set -euo pipefail

    pr="{{pr}}"
    if [[ ! "$pr" =~ ^[0-9]+$ ]]; then
        if [[ "$pr" =~ /pull/([0-9]+) ]]; then
            pr="${BASH_REMATCH[1]}"
        else
            echo "Usage: just review-pr <pr_number|pr_url>"
            exit 1
        fi
    fi

    meta_json="$(gh pr view "$pr" --json url,title,author,baseRefName,headRefName,number)"
    pr_url="$(echo "$meta_json" | jq -r '.url')"
    pr_title="$(echo "$meta_json" | jq -r '.title')"
    pr_author="$(echo "$meta_json" | jq -r '.author.login')"
    pr_base="$(echo "$meta_json" | jq -r '.baseRefName')"
    pr_head="$(echo "$meta_json" | jq -r '.headRefName')"

    echo "🔎 PR #$pr — $pr_title"
    echo "by: $pr_author"
    echo "base: $pr_base  head: $pr_head"
    echo "url: $pr_url"
    echo ""

    base_prompt="$(cat "$HOME/Downloads/pr-review-post-prompt.md")"
    full_prompt="$base_prompt"$'\n\n'"Inputs:"$'\n'"- pr_number: $pr"$'\n'"- pr_url: $pr_url"$'\n'"- event: {{event}}"$'\n'"- dry_run: {{dry_run}}"
    if [[ -n "{{extra}}" ]]; then
        full_prompt="$full_prompt"$'\n'"- extra: {{extra}}"
    fi

    echo "🤖 Running claude (agent mode) to post review..."
    claude -p --dangerously-skip-permissions --output-format text "$full_prompt"

# --- resolve-comments steps (each step = one recipe; orchestrated by `resolve-comments`) ---

# Normalize a PR ref to its number: explicit number/URL, else the current branch's open PR.
# Prints ONLY the number on stdout (logs go to stderr) so it's safe inside $(...).
_pr-number pr="":
    #!/usr/bin/env bash
    set -euo pipefail
    pr="{{pr}}"
    if [[ -z "$pr" ]]; then
        pr="$(gh pr view --json number --jq '.number' 2>/dev/null || true)"
        if [[ -z "$pr" ]]; then
            echo "❌ No PR number given and no open PR found for the current branch." >&2
            echo "   Usage: just resolve-comments [<pr_number|pr_url>]" >&2
            exit 1
        fi
        echo "🔗 No PR passed — using current branch's PR #$pr" >&2
    elif [[ ! "$pr" =~ ^[0-9]+$ ]]; then
        if [[ "$pr" =~ /pull/([0-9]+) ]]; then
            pr="${BASH_REMATCH[1]}"
        else
            echo "Usage: just resolve-comments [<pr_number|pr_url>]" >&2
            exit 1
        fi
    fi
    echo "$pr"

# Make sure the working tree is on the PR's head branch (so fixes land on the right branch).
_checkout-pr-head pr:
    #!/usr/bin/env bash
    set -euo pipefail
    pr="{{pr}}"

    meta_json="$(gh pr view "$pr" --json url,title,headRefName)"
    pr_url="$(echo "$meta_json" | jq -r '.url')"
    pr_title="$(echo "$meta_json" | jq -r '.title')"
    pr_head="$(echo "$meta_json" | jq -r '.headRefName')"

    echo "🔎 PR #$pr — $pr_title"
    echo "   head: $pr_head"
    echo "   url:  $pr_url"

    current_branch="$(git rev-parse --abbrev-ref HEAD)"
    if [[ "$current_branch" != "$pr_head" ]]; then
        echo "🌿 Checking out PR head branch '$pr_head' (was on '$current_branch')..."
        git fetch origin "$pr_head"
        git checkout "$pr_head"
        git pull --ff-only origin "$pr_head" || true
    fi

# Fetch UNRESOLVED review threads → write them to a file and print its path on stdout (empty if none).
# Comment text stays in the file (never interpolated into a prompt). Logs go to stderr.
_fetch-review-threads pr:
    #!/usr/bin/env bash
    set -euo pipefail
    pr="{{pr}}"

    repo_json="$(gh repo view --json owner,name)"
    owner="$(echo "$repo_json" | jq -r '.owner.login')"
    repo="$(echo "$repo_json" | jq -r '.name')"

    threads_query='query($owner:String!,$repo:String!,$pr:Int!){ repository(owner:$owner,name:$repo){ pullRequest(number:$pr){ reviewThreads(first:100){ nodes{ id isResolved isOutdated comments(first:30){ nodes{ databaseId path line body author{login} } } } } } } }'
    threads_json="$(gh api graphql -f query="$threads_query" -f owner="$owner" -f repo="$repo" -F pr="$pr")"
    unresolved="$(echo "$threads_json" | jq -c '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved==false)]')"
    count="$(echo "$unresolved" | jq 'length')"

    if [[ "$count" -eq 0 ]]; then
        echo "✅ No unresolved review threads on PR #$pr — nothing to do." >&2
        exit 0
    fi
    echo "💬 $count unresolved review thread(s) to resolve." >&2

    out_dir="${TMPDIR:-/tmp}/resolve-comments-$pr"
    mkdir -p "$out_dir"
    echo "$unresolved" > "$out_dir/threads.json"
    echo "$out_dir/threads.json"

# Step: claude reads the unresolved threads, applies the requested code fixes, and stages them (no commit).
# Usage: just fix-comments 1234 /path/to/threads.json
fix-comments pr threads_file:
    #!/usr/bin/env bash
    set -euo pipefail
    pr="{{pr}}"
    threads_file="{{threads_file}}"
    pr_url="$(gh pr view "$pr" --json url --jq '.url')"

    fix_prompt="$(cat <<EOF
    You are resolving code review comments on PR #$pr ($pr_url) in the Lumin platform monorepo.

    The unresolved review threads are in this JSON file — read it first:
      $threads_file
    Each entry has the GraphQL thread "id" plus its "comments" (path, line, body, author).

    Instructions:
    - For each unresolved thread, read the comment(s) and apply the requested code change.
    - If a comment is a bot false-positive or genuinely not actionable, do NOT change code for it.
      Make a note of which threads you changed vs. skipped (you will need this in a later step).
    - Follow repo CLAUDE.md / AGENTS.md conventions (gitnexus impact analysis before editing symbols;
      lint with biome where applicable).
    - Stage ONLY the files you changed (git add <paths>). Never stage .env*, .env.keys, or unrelated lock files.
    - Do NOT commit, push, or reply to comments — later steps handle that.
    - Do NOT ask for confirmation. Just implement.
    EOF
    )"
    echo "🤖 claude resolving comments..."
    claude -p --dangerously-skip-permissions --output-format text "$fix_prompt"

# Step: claude replies to each addressed thread (referencing the fix commit) and optionally resolves it.
# Usage: just reply-comments 1234 <head_sha> /path/to/threads.json [resolve_threads=true]
reply-comments pr head_sha threads_file resolve_threads="true":
    #!/usr/bin/env bash
    set -euo pipefail
    pr="{{pr}}"
    head_sha="{{head_sha}}"
    threads_file="{{threads_file}}"

    repo_json="$(gh repo view --json owner,name)"
    owner="$(echo "$repo_json" | jq -r '.owner.login')"
    repo="$(echo "$repo_json" | jq -r '.name')"
    pr_url="$(gh pr view "$pr" --json url --jq '.url')"

    reply_prompt="$(cat <<EOF
    Update the review threads on PR #$pr ($pr_url) in repo $owner/$repo using the gh CLI.

    Latest commit SHA containing the fixes: $head_sha
    The threads you addressed are in: $threads_file (each has GraphQL "id" and "comments").
    resolve_threads = {{resolve_threads}}

    For each thread that was actually addressed by a code change:
    1. Post a brief reply describing what changed, referencing commit $head_sha. Use the FIRST comment's
       databaseId as the reply target:
         gh api -X POST repos/$owner/$repo/pulls/$pr/comments/<first_comment_databaseId>/replies -f body="..."
    2. If resolve_threads is true, resolve the thread (use its GraphQL "id"):
         gh api graphql -f query='mutation(\$t:ID!){resolveReviewThread(input:{threadId:\$t}){thread{isResolved}}}' -F t=<thread_id>

    For threads you intentionally skipped (e.g. bot false-positives), post a short reply explaining why,
    but do NOT resolve them. Keep replies concise. Do NOT reply twice to the same thread.
    EOF
    )"
    echo "🤖 claude updating comments..."
    claude -p --dangerously-skip-permissions --output-format text "$reply_prompt"

# Resolve a PR's review comments with claude IN THE CURRENT working tree — thin orchestrator
# over the step recipes above:
#   _pr-number → _checkout-pr-head → _fetch-review-threads → fix-comments → create-commit → push → reply-comments
# Note: this checks out the PR head branch in the current tree. To run it in an isolated
# worktree instead (leaving your tree untouched), use `just resolve-comments` (wrapper below).
# Usage:
#   just resolve-comments-here                # auto-detect the open PR for the current branch
#   just resolve-comments-here 1234
#   just resolve-comments-here https://github.com/<org>/<repo>/pull/1234
#   just resolve-comments-here 1234 resolve_threads=false   # reply only, leave threads open
resolve-comments-here pr="" resolve_threads="true":
    #!/usr/bin/env bash
    set -euo pipefail

    # 1. Resolve PR number (explicit arg or current branch's open PR)
    pr="$(just _pr-number "{{pr}}")"

    # 2. Make sure we're on the PR head branch
    just _checkout-pr-head "$pr"

    # 3. Fetch unresolved review threads (empty path → nothing to do)
    threads_file="$(just _fetch-review-threads "$pr")"
    if [[ -z "$threads_file" ]]; then
        exit 0
    fi
    trap 'rm -rf "$(dirname "$threads_file")"' EXIT

    # 4. claude fixes code + stages it
    echo "🤖 [1/4] resolving comments..."
    just fix-comments "$pr" "$threads_file"

    # 5. commit + push (only if claude staged something)
    if git diff --cached --quiet; then
        echo "ℹ️  No staged changes produced — skipping commit/push (claude may have deemed all comments non-actionable)."
    else
        echo "📝 [2/4] committing staged changes..."
        just create-commit "resolve PR #$pr review comments"
        echo "🚀 [3/4] pushing..."
        git push
    fi

    # 6. claude replies to + resolves each addressed thread
    head_sha="$(git rev-parse HEAD)"
    echo "🤖 [4/4] updating comments..."
    just reply-comments "$pr" "$head_sha" "$threads_file" "{{resolve_threads}}"

    echo "✅ Done — PR #$pr review comments handled."

# Resolve a PR's review comments in an ISOLATED worktree (via worktrunk), so your current
# working tree / branch stays untouched while claude works. This is the default entrypoint.
#
# Flow: `wt switch pr:<N>` creates a worktree on the PR's head branch → copy the (untracked)
# just files + .env.keys into it → run `just resolve-comments-here` there.
#
# Caveats:
#   - justfile, remote.just & .env.keys are untracked/gitignored, so they're copied into the
#     fresh worktree (it's ephemeral — they vanish with `wt remove`).
#   - The PR's branch must NOT already be checked out elsewhere (git forbids the same branch
#     in two worktrees). If you're sitting on it now, commit/stash and switch off it first.
#   - The worktree is left in place when done — inspect with `wt list`, remove with `wt remove`.
#
# Usage:
#   just resolve-comments 1234
#   just resolve-comments 1234 resolve_threads=false
resolve-comments pr resolve_threads="true":
    #!/usr/bin/env bash
    set -euo pipefail
    src="{{justfile_directory()}}"
    echo "🌳 Creating worktree for PR #{{pr}} and resolving its comments there..."
    wt switch "pr:{{pr}}" -x bash -- -c "cp '$src/justfile' '$src/remote.just' '$src/.env.keys' . && just resolve-comments-here '{{pr}}' '{{resolve_threads}}'"
