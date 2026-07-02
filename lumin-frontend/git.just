# Lumin frontend — git & PR workflow (cherry-pick, branch, commit, create-pr)
# Part of the remote template. Imported by the fetched `remote.just`.

cherry-cards from +cards:
    #!/usr/bin/env bash
    set -euo pipefail

    source="{{from}}"
    IFS=', ' read -ra cards <<< "{{cards}}"

    grep_args=()
    for card in "${cards[@]}"; do
        [[ -z "$card" ]] && continue
        grep_args+=(--grep="WO-${card}")
    done

    if [[ ${#grep_args[@]} -eq 0 ]]; then
        echo "Usage: just cherry-cards <source-branch> 896 399 855"
        exit 1
    fi

    if ! git rev-parse --verify "$source" &>/dev/null; then
        echo "❌ Branch '${source}' does not exist"
        exit 1
    fi

    current_branch=$(git rev-parse --abbrev-ref HEAD)
    # -i so `WO-1070` also matches prefixed scopes like `e2e-wo-1070` / `E2E-WO-1070`.
    mapfile -t lines < <(git log --oneline --no-merges --reverse -i "$source" "${grep_args[@]}")

    if [[ ${#lines[@]} -eq 0 ]]; then
        echo "❌ No commits found on ${source} matching: WO-{${cards[*]}}"
        exit 1
    fi

    echo "📋 Found ${#lines[@]} commit(s) for WO-{${cards[*]}} on ${source} (oldest → newest):"
    echo "   Cherry-pick onto: ${current_branch}"
    echo ""

    pick_shas=()
    for line in "${lines[@]}"; do
        sha="${line%% *}"
        if git merge-base --is-ancestor "$sha" HEAD 2>/dev/null; then
            echo "  ✓ ${line}  (already on ${current_branch})"
        else
            echo "    ${line}"
            pick_shas+=("$sha")
        fi
    done
    echo ""

    if [[ ${#pick_shas[@]} -eq 0 ]]; then
        echo "All commits already on ${current_branch}. Nothing to cherry-pick."
        exit 0
    fi

    read -rp "🍒 Cherry-pick ${#pick_shas[@]} commit(s) onto ${current_branch}? [y/N] " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        git cherry-pick "${pick_shas[@]}"
        echo "✅ Done — ${#pick_shas[@]} commit(s) cherry-picked onto ${current_branch}"
    else
        echo "Aborted."
    fi


# Sync release refs in the main repo WITHOUT switching the current branch:
# fast-forward develop-opt (cherry-pick source) and staging (worktree base) from origin.
# Usage: just sync-release-refs
sync-release-refs:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "🔄 Syncing develop-opt + staging from origin (fast-forward only)..."

    # git refuses `origin/<br>:<br>` for a branch that's the active HEAD of a worktree,
    # so fast-forward the checked-out branch with `pull --ff-only` and use the refspec
    # form only for the branch that isn't checked out.
    current="$(git rev-parse --abbrev-ref HEAD)"
    for br in develop-opt staging; do
        if [[ "$br" == "$current" ]]; then
            echo "  ↪ fast-forwarding checked-out ${br}..."
            git pull --ff-only origin "$br"
        else
            echo "  ↪ fast-forwarding ${br}..."
            git fetch origin "${br}:${br}"
        fi
    done

# Seed a fresh worktree with the gitignored fetched just templates + .env.keys so recipes resolve inside it.
# Usage: just _seed-worktree <main_root> <worktree_path>
_seed-worktree main_root worktree_path:
    #!/usr/bin/env bash
    set -euo pipefail
    main_root="{{main_root}}"
    worktree_path="{{worktree_path}}"
    cp "$main_root/justfile" "$main_root"/*.just "$worktree_path"/
    if [[ -f "$main_root/.env.keys" ]]; then
        cp "$main_root/.env.keys" "$worktree_path"/
    fi

# Build the release worktree and cherry-pick inside it. Runs inside the freshly-opened tmux window.
# wt creates the branch off staging; we copy the (gitignored) just templates in, cherry-pick, then
# leave you in an interactive shell in the worktree for review / create-pr.
_release-worktree-window branch version from pipeline:
    #!/usr/bin/env bash
    set -euo pipefail
    branch="{{branch}}"
    version="{{version}}"
    from="{{from}}"
    pipeline="{{pipeline}}"

    main_root="$(git rev-parse --show-toplevel)"

    # 1. Resolve/create the worktree for this branch (reuse if present, else create off staging).
    find_worktree() {
        git worktree list --porcelain \
            | awk -v b="refs/heads/${branch}" '/^worktree /{p=$2} $0=="branch "b{print p}'
    }
    worktree_path="$(find_worktree)"
    if [[ -n "$worktree_path" ]]; then
        echo "🌿 Reusing existing worktree: ${worktree_path}"
    else
        echo "🌱 Creating worktree for ${branch} (base: staging)..."
        if git show-ref --verify --quiet "refs/heads/${branch}"; then
            wt switch "$branch" --yes --no-cd            # branch exists → don't recreate it
        else
            wt switch --create "$branch" --base staging --yes --no-cd
        fi
        worktree_path="$(find_worktree)"
    fi

    # 2. Bail clearly if we still can't locate it
    if [[ -z "$worktree_path" ]]; then
        echo "❌ Could not locate worktree for ${branch}"
        exit 1
    fi
    echo "📂 Worktree: ${worktree_path}"

    # 3. The just templates are gitignored fetched artifacts, so a fresh worktree has none —
    #    copy them (incl. this git.just) + .env.keys over so the recipes below resolve inside the worktree.
    just _seed-worktree "$main_root" "$worktree_path"

    cd "$worktree_path"

    # 4. Cherry-pick the Linear release cards inside the worktree
    just no-checkout
    just cherry-linear-release "$version" "$from" "$pipeline"

    # 5. Stay in an interactive shell in the worktree for review / create-pr
    echo "✅ Release worktree ready at ${worktree_path}"
    exec "${SHELL:-/bin/zsh}" -l

# Open a new tmux window (focused) that builds the release worktree and runs the cherry-pick in it.
_open-release-window branch version from pipeline:
    #!/usr/bin/env bash
    set -euo pipefail
    branch="{{branch}}"
    version="{{version}}"
    from="{{from}}"
    pipeline="{{pipeline}}"

    if [[ -z "${TMUX:-}" ]]; then
        echo "❌ Not inside a tmux session — start tmux first, then re-run."
        exit 1
    fi

    repo_root="$(git rev-parse --show-toplevel)"
    window_name="${branch}"
    echo "🪟 Opening tmux window '${window_name}' for ${branch}..."
    # `|| exec $SHELL` keeps the window open if the recipe fails, so the error stays readable
    # (on success the recipe exec's its own shell in the worktree and never returns here).
    tmux new-window -c "$repo_root" -n "$window_name" \
        "just _release-worktree-window '${branch}' '${version}' '${from}' '${pipeline}' || exec \${SHELL:-/bin/zsh} -l"
    echo "➡️  Continue in tmux window '${window_name}'."

# Fetch Linear release cards and cherry-pick them onto the current branch.
# Usage: just cherry-linear-release "0.25.0" develop-opt
cherry-linear-release version from="develop-opt" pipeline="Web Optimization Releases":
    #!/usr/bin/env bash
    set -euo pipefail
    : "${LINEAR_API_KEY:?LINEAR_API_KEY is required}"

    # Fetch Linear release cards and cherry-pick
    query='{ "query": "query Issues { issues(filter: { releases: { name: { eq: \"{{version}}\" }, pipeline: { name: { eq: \"{{pipeline}}\" } } } }) { edges { node { number } } } }" }'
    numbers=$(curl -s -X POST https://api.linear.app/graphql \
      -H "Content-Type: application/json" \
      -H "Authorization: ${LINEAR_API_KEY}" \
      -d "$query" | jq -r '.data.issues.edges[].node.number')

    if [[ -z "$numbers" ]]; then
        echo "❌ No issues found in release {{version}} (pipeline: {{pipeline}})"
        exit 1
    fi

    echo "📋 Linear release {{version}} cards:"
    echo "$numbers" | while read -r n; do echo "  WO-$n"; done
    echo ""

    just cherry-cards "{{from}}" $numbers

# Create a release: sync refs, open a tmux window, build the worktree off staging, cherry-pick Linear cards.
# Defaults to a private pre-release/… branch; pass prefix="release/" for a public release branch.
# Usage: just create-release "0.25.0"                        # -> pre-release/lumin-web-optimization-0.25.0
#        just create-release "0.25.0" develop-opt            # override cherry-pick source
#        just create-release "0.25.0" prefix="release/"      # public release branch
create-release version from="develop-opt" pipeline="Web Optimization Releases" product="lumin-web-optimization" prefix="pre-release/": sync-release-refs
    #!/usr/bin/env bash
    set -euo pipefail
    just _open-release-window "{{prefix}}{{product}}-{{version}}" "{{version}}" "{{from}}" "{{pipeline}}"

# Remove ONE ticket's worktree (created by `linear-task`). The branch is matched by its
# `wo-<n>` token, so a bare number or the full id both work. The branch is deleted only when
# it's merged into the default branch; pass a non-empty `force` (e.g. 1) to remove a
# dirty/unmerged worktree and force-delete its branch.
# NB: uses plain git — `wt remove` mis-resolves the default branch in this repo (no local `main`).
# Usage:
#   just wt-clean WO-1065        # remove WO-1065's worktree (branch deleted if merged)
#   just wt-clean 1065           # same, bare card number
#   just wt-clean 1065 1         # force — remove even if dirty/unmerged, force-delete the branch
#   just wt-clean 1065 "" ENG    # different team prefix (ENG-1065)
wt-clean card force="" team="WO":
    #!/usr/bin/env bash
    set -euo pipefail

    card="{{card}}"
    team="{{team}}"

    # Normalize to the `wo-<n>` token used in branch names (WO-1065 / 1065 → wo-1065).
    if [[ "$card" =~ ^[0-9]+$ ]]; then
        token="$(echo "${team}-${card}" | tr '[:upper:]' '[:lower:]')"
    else
        token="$(echo "$card" | tr '[:upper:]' '[:lower:]')"
    fi

    # Find the worktree path + branch carrying that token (anchored so wo-1065 ≠ wo-10650).
    match="$(git worktree list --porcelain | awk '
        /^worktree /{p=$2}
        /^branch /{b=$2; sub("refs/heads/","",b); print p"\t"b}
    ' | grep -iE -- "(-|/)${token}(-|\$)" | head -n1 || true)"

    if [[ -z "$match" ]]; then
        echo "❌ No worktree found for ${token}. Current worktrees:"
        git worktree list
        exit 1
    fi
    path="${match%%$'\t'*}"
    branch="${match#*$'\t'}"

    echo "🗑  Removing worktree: ${path}  [${branch}]"
    if [[ -n "{{force}}" ]]; then
        git worktree remove --force "$path"
        git branch -D "$branch" 2>/dev/null || true
    else
        git worktree remove "$path"                 # refuses if the worktree is dirty
        git branch -d "$branch" 2>/dev/null || echo "   ↳ branch ${branch} kept (not merged; re-run with force=1 to delete)"
    fi
    git worktree prune
    echo "✅ Removed ${branch}"

# Prune ALL worktrees whose branch is already merged into the default branch (origin/HEAD).
# Clean, merged worktrees are removed and their branches deleted; unmerged/dirty ones are kept.
# Override the default branch with `base` (e.g. develop-opt) if you don't merge into main.
# NB: uses plain git — `wt step prune` mis-resolves the default branch in this repo.
# Usage:
#   just wt-prune               # remove worktrees merged into origin/main
#   just wt-prune develop-opt   # merged-check against origin/develop-opt instead
wt-prune base="":
    #!/usr/bin/env bash
    set -euo pipefail
    just _wt-prune "{{base}}" ""

# Preview `wt-prune` — show which worktrees would be removed/kept, change nothing.
# Usage: just wt-prune-dry   |   just wt-prune-dry develop-opt
wt-prune-dry base="":
    #!/usr/bin/env bash
    set -euo pipefail
    just _wt-prune "{{base}}" "dry"

# Shared prune engine for wt-prune / wt-prune-dry. Merged-check runs against origin/<default>.
_wt-prune base dry:
    #!/usr/bin/env bash
    set -euo pipefail
    dry="{{dry}}"

    main_wt="$(git worktree list --porcelain | awk '/^worktree /{print $2; exit}')"

    # Resolve the integration branch feature worktrees merge back into:
    #   explicit base → the primary worktree's current branch → develop-opt.
    # (origin/HEAD points at main, which this sparse clone doesn't fetch — so don't use it.)
    default="{{base}}"
    if [[ -z "$default" ]]; then
        default="$(git -C "$main_wt" symbolic-ref --short HEAD 2>/dev/null || true)"
        default="${default:-develop-opt}"
    fi
    git fetch --quiet origin "$default" 2>/dev/null || true
    ref="origin/${default}"
    git rev-parse --verify --quiet "$ref" >/dev/null || ref="$default"
    base_sha="$(git rev-parse --verify --quiet "$ref")" || { echo "❌ Cannot resolve base branch ref: ${default} (pass one, e.g. \`just wt-prune develop-opt\`)"; exit 1; }

    [[ -n "$dry" ]] && echo "🔍 Dry run — worktrees merged into ${ref}:" || echo "🧹 Pruning worktrees merged into ${ref}..."
    removed=0
    while IFS=$'\t' read -r path branch; do
        [[ -z "$branch" ]] && continue
        [[ "$path" == "$main_wt" ]] && continue          # never touch the primary worktree
        [[ "$branch" == "$default" ]] && continue
        tip="$(git rev-parse --verify --quiet "refs/heads/$branch")" || continue
        if git merge-base --is-ancestor "$tip" "$base_sha"; then
            if [[ -n "$dry" ]]; then
                echo "  🗑  would remove  ${branch}  (${path})"
            else
                echo "  🗑  removing  ${branch}"
                if git worktree remove "$path" 2>/dev/null; then
                    git branch -d "$branch" 2>/dev/null || true
                    removed=$((removed+1))
                else
                    echo "     ↳ skipped (dirty worktree — clean it or use \`just wt-clean ${branch} 1\`)"
                fi
            fi
        else
            echo "  ·  keep  ${branch}  (not merged)"
        fi
    done < <(git worktree list --porcelain | awk '
        /^worktree /{p=$2}
        /^branch /{b=$2; sub("refs/heads/","",b); print p"\t"b}
    ')

    if [[ -z "$dry" ]]; then
        git worktree prune
        echo "✅ Prune complete — removed ${removed} worktree(s)."
    fi

# Create a commit using claude following the project commit convention (.agents/skills/commit)
# Usage:
#   just create-commit              # commit staged files (or auto-group unstaged)
#   just create-commit "fix login"  # hint to guide the commit message
create-commit hint="":
    #!/usr/bin/env bash
    set -euo pipefail
    skill_file=".agents/skills/commit/SKILL.md"
    if [[ ! -f "$skill_file" ]]; then
        echo "❌ Commit skill not found: $skill_file"
        exit 1
    fi
    skill="$(cat "$skill_file")"
    hint="{{hint}}"
    tmpfile="$(mktemp /tmp/create-commit-XXXXXX.txt)"
    trap 'rm -f "$tmpfile"' EXIT
    {
        echo "Follow the commit skill instructions below EXACTLY to create a git commit."
        echo ""
        echo "=== COMMIT SKILL ==="
        echo "$skill"
        echo "=== END SKILL ==="
        echo ""
        echo "Additional instructions:"
        echo "- You MUST follow the skill steps: check staged files, inspect diffs, determine type/scope/subject, and commit."
        echo "- Do NOT ask for confirmation. Just commit."
        echo "- Do NOT amend any existing commit."
        echo "- Do NOT push after committing."
        if [[ -n "$hint" ]]; then
            echo ""
            echo "User hint for this commit: $hint"
        fi
    } > "$tmpfile"
    prompt="$(cat "$tmpfile")"
    echo "🤖 Running claude to create commit..."
    claude -p --dangerously-skip-permissions --output-format text "$prompt"

# Create a feature branch from origin/develop-opt using Linear's suggested branch name.
# Usage:
#   just create-branch 820
#   just create-branch WO-820
#   just create-branch 820 prefix="feature/"
#   just create-branch 820 base="develop-opt"
create-branch card base="develop-opt" prefix="feature/" team="WO":
    #!/usr/bin/env bash
    set -euo pipefail

    : "${LINEAR_API_KEY:?LINEAR_API_KEY is required}"

    card="{{card}}"
    team="{{team}}"
    base="{{base}}"
    prefix="{{prefix}}"

    if [[ "$card" =~ ^[0-9]+$ ]]; then
        identifier="${team}-${card}"
    else
        identifier="$card"
    fi

    query="$(jq -cn --arg id "$identifier" '{
      query: "query Issue($id: String!) { issue(id: $id) { id identifier title branchName } }",
      variables: {id: $id}
    }')"

    resp="$(curl -s -X POST https://api.linear.app/graphql \
      -H "Content-Type: application/json" \
      -H "Authorization: ${LINEAR_API_KEY}" \
      -d "$query")"

    linear_id="$(echo "$resp" | jq -r '.data.issue.identifier // empty')"
    title="$(echo "$resp" | jq -r '.data.issue.title // empty')"
    branch_name="$(echo "$resp" | jq -r '.data.issue.branchName // empty')"

    if [[ -z "$linear_id" ]]; then
        msg="$(echo "$resp" | jq -r '.errors[0].message // empty')"
        echo "❌ Could not find Linear issue: ${identifier}"
        [[ -n "$msg" ]] && echo "   ${msg}"
        exit 1
    fi

    if [[ -z "$branch_name" ]]; then
        slug="$(echo "$title" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed -E 's/^-+//; s/-+$//')"
        branch_name="$(echo "$linear_id" | tr '[:upper:]' '[:lower:]')-${slug}"
    fi

    branch="${branch_name}"
    branch="$(echo "$branch" | tr '[:upper:]' '[:lower:]' | tr -s '/')"

    echo "🎫 Linear: ${linear_id} — ${title}"
    echo "🌿 Base: origin/${base}"
    echo "🌱 Branch: ${branch}"

    git fetch origin "${base}"
    if git show-ref --verify --quiet "refs/heads/${base}"; then
        git checkout "${base}"
        git pull --ff-only origin "${base}"
    fi
    if git show-ref --verify --quiet "refs/heads/${branch}"; then
        git checkout "${branch}"
    else
        git checkout -b "${branch}" "origin/${base}"
    fi

# Open/update the staging release PR — shorthand for `create-pr staging` (PR base = staging).
# Usage: just create-pr-pre-release
#        just create-pr-pre-release source="develop-opt"
create-pr-pre-release pipeline="Web Optimization Releases" source="develop-opt":
    just create-pr staging "{{pipeline}}" "{{source}}"

# Open/update draft PR. Base `staging`: version from branch name, Linear release URL via API (same as create-release), then claude + PR-TEMPLATE.md.
create-pr branch="develop-opt" pipeline="Web Optimization Releases" source="develop-opt":
    #!/usr/bin/env node
    const { execSync, execFileSync } = require("child_process");
    const fs = require("fs");
    const os = require("os");
    const path = require("path");

    const BASE = "{{branch}}";
    const RELEASE_PIPELINE = "{{pipeline}}";
    const RELEASE_SOURCE_BRANCH = "{{source}}";
    const REVIEWERS = "khanhNguyenLuminPdf,longhn-lumin,EdwardTran99";
    const LABEL = "dev-0ptimazation";
    const STAGING_PR_TEMPLATE = "/Users/dev/Downloads/PR-TEMPLATE.md";
    const LINEAR_API_KEY = process.env.LINEAR_API_KEY;
    if (!LINEAR_API_KEY) {
        throw new Error("LINEAR_API_KEY is required");
    }

    function run(cmd) {
        return execSync(cmd, { encoding: "utf-8", stdio: ["inherit", "pipe", "inherit"] }).trim();
    }

    /** No shell — prompt is argv. stdin must be ignored or agent hangs waiting for TTY input. */
    function runClaude(prompt, label = "PR description") {
        console.error(`⏳ Generating ${label} with claude (often 30s–3min, no output until done)...`);
        const started = Date.now();
        try {
            const out = execFileSync(
                "claude",
                [
                    "-p",
                    "--permission-mode",
                    "plan",
                    "--output-format",
                    "text",
                    prompt,
                ],
                {
                    encoding: "utf-8",
                    stdio: ["ignore", "pipe", "inherit"],
                    maxBuffer: 16 * 1024 * 1024,
                },
            ).trim();
            console.error(`✓ ${label} ready (${Math.round((Date.now() - started) / 1000)}s)`);
            return out;
        } catch (err) {
            if (err.killed || err.signal === "SIGTERM") {
                console.error("❌ claude timed out");
            }
            throw err;
        }
    }

    function pushBranch() {
        const branch = run("git rev-parse --abbrev-ref HEAD");
        run(`git push -u origin "${branch}"`);
        return branch;
    }

    function findOpenPr(branch) {
        return run(`gh pr list --head "${branch}" --state open --json url --jq ".[].url"`);
    }

    function getCachePath(branch) {
        const cacheDir = path.join(os.tmpdir(), "just-create-pr");
        if (!fs.existsSync(cacheDir)) fs.mkdirSync(cacheDir, { recursive: true });
        const safeBranch = branch.replace(/\//g, "_");
        const safeBase = BASE.replace(/\//g, "_");
        return path.join(cacheDir, `${safeBranch}__base_${safeBase}.json`);
    }

    function readCache(cacheFile) {
        return fs.existsSync(cacheFile) ? JSON.parse(fs.readFileSync(cacheFile, "utf-8")) : null;
    }

    function loadStagingTemplate() {
        if (!fs.existsSync(STAGING_PR_TEMPLATE)) {
            console.error(`❌ PR template not found: ${STAGING_PR_TEMPLATE}`);
            process.exit(1);
        }
        return fs.readFileSync(STAGING_PR_TEMPLATE, "utf-8");
    }

    function linearGraphql(query, variables = {}) {
        const payload = JSON.stringify({ query, variables });
        const raw = execFileSync(
            "curl",
            [
                "-sS",
                "-X",
                "POST",
                "https://api.linear.app/graphql",
                "-H",
                "Content-Type: application/json",
                "-H",
                `Authorization: ${LINEAR_API_KEY}`,
                "-d",
                payload,
            ],
            { encoding: "utf-8", stdio: ["ignore", "pipe", "pipe"] },
        );
        const json = JSON.parse(raw);
        if (json.errors?.length) {
            throw new Error(json.errors.map((e) => e.message).join("; "));
        }
        return json.data;
    }

    /** For no-PR tickets: the "dev" is the last person who moved the card into `On Dev-Opt`.
     *  Linear returns a display name; map it to a GitHub handle so it can be @-tagged. */
    const DEV_OPT_STATE = "On Dev-Opt";
    const LINEAR_NAME_TO_GITHUB = {
        "Long Hang": "longhn-lumin",
        "Phu Nguyen": "phunq-lumin",
        "Khanh Nguyen": "khanhNguyenLuminPdf",
        "Thinh Tran (Edward)": "EdwardTran99",
    };
    /** Render a Linear display name as an @-mention when we know its GitHub handle;
     *  otherwise fall back to the plain name (won't tag), or — when empty. */
    const formatDevName = (name) => {
        if (!name) return "—";
        const gh = LINEAR_NAME_TO_GITHUB[name];
        return gh ? `@${gh}` : name;
    };
    function lastDevOptMover(issueId) {
        try {
            const data = linearGraphql(
                `query IssueHistory($id: String!) {
                  issue(id: $id) {
                    history(last: 250) {
                      nodes { createdAt actor { name } toState { name } }
                    }
                  }
                }`,
                { id: issueId },
            );
            const moves = (data?.issue?.history?.nodes ?? []).filter(
                (n) => n.toState?.name === DEV_OPT_STATE && n.actor?.name,
            );
            if (!moves.length) return "";
            moves.sort((a, b) => (a.createdAt < b.createdAt ? -1 : 1));
            return moves[moves.length - 1].actor.name;
        } catch {
            return "";
        }
    }

    function parseReleaseVersionFromBranch(branch) {
        const match = branch.match(/(\d+\.\d+\.\d+)\s*$/);
        if (!match) {
            console.error(`❌ Cannot parse release version from branch: ${branch}`);
            console.error("   Expected e.g. release/lumin-web-optimization-0.19.0");
            process.exit(1);
        }
        return match[1];
    }

    function parseProductLabelFromBranch(branch, version) {
        const slugMatch = branch.match(/^(?:pre-)?release\/(.+)-\d+\.\d+\.\d+$/);
        if (slugMatch) {
            const title = slugMatch[1]
                .split("-")
                .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
                .join(" ");
            return `${title} v${version}`;
        }
        return `Lumin Web Optimization v${version}`;
    }

    /** Same issue filter as create-release; releases filter for the PR link URL. */
    function fetchLinearStagingContext(version) {
        console.error(`📡 Linear: release ${version} (${RELEASE_PIPELINE})...`);

        const issuesData = linearGraphql(
            `query Issues($version: String!, $pipeline: String!) {
              issues(
                filter: {
                  releases: { name: { eq: $version }, pipeline: { name: { eq: $pipeline } } }
                }
              ) {
                edges { node { number title labels { nodes { name } } attachments { nodes { url } } } }
              }
            }`,
            { version, pipeline: RELEASE_PIPELINE },
        );

        const releasesData = linearGraphql(
            `query Releases($version: String!, $pipeline: String!) {
              releases(
                filter: {
                  pipeline: { name: { eq: $pipeline } }
                  name: { eq: $version }
                }
              ) {
                nodes {
                  name
                  version
                  url
                  pipeline { name }
                }
              }
            }`,
            { version, pipeline: RELEASE_PIPELINE },
        );

        const release = releasesData?.releases?.nodes?.[0];

        if (!release?.url) {
            console.error(
                `❌ No Linear release URL for version ${version} (pipeline: ${RELEASE_PIPELINE})`,
            );
            process.exit(1);
        }

        const PR_URL_RE = /https?:\/\/github\.com\/[^/]+\/[^/]+\/pull\/(\d+)/i;

        // The Linear assignee is QC — the developer is whoever created the PR.
        // Resolve the PR author's GitHub login via `gh`, memoized per URL.
        const prAuthorCache = {};
        const resolvePrAuthor = (url) => {
            if (url in prAuthorCache) return prAuthorCache[url];
            let login = "";
            try {
                login = run(`gh pr view "${url}" --json author --jq ".author.login"`);
            } catch {
                login = "";
            }
            prAuthorCache[url] = login;
            return login;
        };

        const issues = (issuesData?.issues?.edges ?? []).map(({ node }) => {
            const prs = [
                ...new Set(
                    (node.attachments?.nodes ?? [])
                        .map((a) => a.url ?? "")
                        .filter((url) => PR_URL_RE.test(url)),
                ),
            ];
            const devs = [...new Set(prs.map(resolvePrAuthor).filter(Boolean))];
            return {
                id: `WO-${node.number}`,
                title: node.title ?? "",
                prs,
                labels: (node.labels?.nodes ?? []).map((l) => l.name),
                devs,
            };
        });

        console.error(`   Linear release: ${release.url}`);
        console.error(`   Tickets: ${issues.length}`);

        return {
            version,
            pipeline: RELEASE_PIPELINE,
            linearReleaseUrl: release.url,
            issues,
        };
    }

    function formatLinearIssuesBlock(issues) {
        if (!issues.length) return "(none returned from Linear for this release)";
        return issues
            .map((row) => {
                const prs = row.prs?.length ? ` | PRs: ${row.prs.join(", ")}` : "";
                const labels = row.labels?.length ? ` | Labels: ${row.labels.join(", ")}` : "";
                const devs = row.devs?.length ? ` | Devs: ${row.devs.map((d) => `@${d}`).join(", ")}` : "";
                return `- ${row.id}: ${row.title}${prs}${labels}${devs}`;
            })
            .join("\n");
    }

    function applyLinearReleaseUrl(body, ctx) {
        const linkLabel = `${ctx.version} — ${ctx.pipeline}`;
        const line = `**Linear Release:** [${linkLabel}](${ctx.linearReleaseUrl})`;
        if (/\*\*Linear Release:\*\*/i.test(body)) {
            return body.replace(/\*\*Linear Release:\*\*[^\n]*/i, line);
        }
        const intro = /(Cherry-picked[^\n]+\n\n)/i;
        if (intro.test(body)) {
            return body.replace(intro, `$1${line}\n\n`);
        }
        return `${line}\n\n${body}`;
    }

    function generateDescription() {
        const diff = run(`git log --oneline "${BASE}...HEAD"`);
        const prompt = [
            "Generate a concise GitHub PR description in markdown for the following commits.",
            'Include a "## Summary" section with 1-3 bullet points and a "## Test plan" section with a checklist.',
            "Output ONLY the markdown, no extra text.",
            "",
            diff,
        ].join("\n");
        console.log("Generating PR description with claude...");
        return runClaude(prompt);
    }

    function generateStagingDescription(headBranch) {
        const version = parseReleaseVersionFromBranch(headBranch);
        const productLabel = parseProductLabelFromBranch(headBranch, version);
        const linear = fetchLinearStagingContext(version);
        // Per-label CMS sections: cards carrying one of these labels are content changes,
        // not code deploys — each gets a table + a clickable checklist below Included tickets.
        const CMS_LABEL_SECTIONS = [
            {
                label: "Prismic CMS",
                heading: "### Prismic / Slice Machine updates",
                intro: "Content changes published in Prismic / Slice Machine — NOT deployed by merging this PR.",
                checklistLabel: "**Publish checklist** — tick each once its content is published:",
                item: (id) => `- [ ] ${id} published in Prismic / Slice Machine`,
            },
            {
                label: "Strapi CMS",
                heading: "### Strapi CMS updates",
                intro: "Content managed in Strapi — verify the corresponding code in the strapi repo before release.",
                checklistLabel: "**Check code in repo strapi** — tick each once verified:",
                item: (id) => `- [ ] ${id} — check code in repo strapi`,
            },
        ];

        const cmsSections = CMS_LABEL_SECTIONS.map((cfg) => {
            const tickets = linear.issues.filter((i) => (i.labels ?? []).includes(cfg.label));
            if (!tickets.length) return null;
            // Unique dev handles from this section's table — @-tagged on the last checklist line.
            const devMentions = [...new Set(tickets.flatMap((t) => t.devs ?? []))].map((d) => `@${d}`);
            const md = [
                cfg.heading,
                "",
                cfg.intro,
                "",
                "| Ticket | Title | Dev |",
                "|--------|-------|-----|",
                ...tickets.map(
                    (t) =>
                        `| [${t.id}](https://linear.app/luminpdf/issue/${t.id}) | ${t.title} | ${t.devs?.length ? t.devs.map((d) => `@${d}`).join(", ") : "—"} |`,
                ),
                "",
                cfg.checklistLabel,
                ...tickets.map((t) => cfg.item(t.id)),
                ...(devMentions.length ? [`- [ ] ${devMentions.join(" ")} — please confirm the above`] : []),
            ].join("\n");
            return { label: cfg.label, tickets, md };
        }).filter(Boolean);

        const cmsTicketIds = [...new Set(cmsSections.flatMap((s) => s.tickets.map((t) => t.id)))];
        for (const s of cmsSections) {
            console.error(`   ${s.label} tickets: ${s.tickets.map((t) => t.id).join(", ")}`);
        }

        // Tickets with no linked PR (excluding CMS tickets, which have their own section above).
        // Dev here = last person who moved the card into `On Dev-Opt` (Linear name, not @-tagged).
        const cmsIdSet = new Set(cmsTicketIds);
        const noPrTickets = linear.issues
            .filter((i) => !i.prs?.length && !cmsIdSet.has(i.id))
            .map((i) => ({ ...i, dev: lastDevOptMover(i.id) }));
        // Unique dev handles/names from the no-PR table — @-tagged on the last checklist line.
        const noPrDevMentions = [
            ...new Set(noPrTickets.map((t) => formatDevName(t.dev)).filter((d) => d && d !== "—")),
        ];
        const noPrSectionMd = noPrTickets.length
            ? [
                  "### Tickets without a PR",
                  "",
                  "These release tickets have no linked GitHub PR — confirm before finalizing.",
                  "",
                  "| Ticket | Title | Dev |",
                  "|--------|-------|-----|",
                  ...noPrTickets.map(
                      (t) =>
                          `| [${t.id}](https://linear.app/luminpdf/issue/${t.id}) | ${t.title} | ${formatDevName(t.dev)} |`,
                  ),
                  "",
                  "**Checklist** — tick each once resolved:",
                  ...noPrTickets.map(
                      (t) => `- [ ] ${t.id} — PR linked in Linear, or confirmed no code change needed`,
                  ),
                  ...(noPrDevMentions.length ? [`- [ ] ${noPrDevMentions.join(" ")} — please confirm the above`] : []),
              ].join("\n")
            : "";
        if (noPrTickets.length) {
            console.error(
                `   Tickets without a PR: ${noPrTickets.map((t) => `${t.id} (dev: ${t.dev || "—"})`).join(", ")}`,
            );
        }

        // All extra sections inserted below the Included tickets table, in order.
        const extraSections = [...cmsSections.map((s) => s.md), noPrSectionMd].filter(Boolean);
        const extraSectionsMd = extraSections.join("\n\n");
        const template = loadStagingTemplate();
        const commitsOneline = run(`git log --oneline "${BASE}...HEAD"`);
        const commitCount = commitsOneline ? commitsOneline.split("\n").length : 0;

        const prompt = [
            "Write a GitHub release PR description for the Lumin platform monorepo.",
            "",
            "Use the following document as the format guide (Output Template, Formatting Rules, Type Classification, Notes & Warnings callouts).",
            "Fill every placeholder with real values inferred from the context below.",
            "Do NOT paste or echo the guide document. Do NOT include meta sections (Required Inputs, Example Invocation, etc.).",
            "Output ONLY the finished PR description markdown ready to post on GitHub.",
            "Do NOT append any explanation, rationale, or 'Notes on choices' / 'Notes:' section describing what you included or omitted. Make the judgment calls silently — the PR body must contain no meta-commentary about your own decisions.",
            "",
            "--- PR template guide ---",
            template,
            "--- end guide ---",
            "",
            "Resolved release metadata (use exactly — do not guess or change the Linear URL):",
            `- Product + version title: ${productLabel}`,
            `- Release version: ${version}`,
            `- Source branch: ${RELEASE_SOURCE_BRANCH}`,
            `- Target branch (PR base): ${BASE}`,
            `- Head branch: ${headBranch}`,
            `- Linear pipeline: ${RELEASE_PIPELINE}`,
            `- Linear release URL (required in **Linear Release:** link): ${linear.linearReleaseUrl}`,
            `- Linear release link label: ${version} — ${RELEASE_PIPELINE}`,
            "",
            "Linear tickets in this release (from API — use for Included tickets table):",
            formatLinearIssuesBlock(linear.issues),
            "",
            `Commits cherry-picked onto this branch (${commitCount}):`,
            commitsOneline || "(no commits)",
            "",
            "Instructions:",
            `- Header: ## Release ${productLabel}`,
            `- Opening line: Cherry-picked fixes and improvements from \`${RELEASE_SOURCE_BRANCH}\` into \`${BASE}\`.`,
            `- **Linear Release:** must be exactly: [${version} — ${RELEASE_PIPELINE}](${linear.linearReleaseUrl})`,
            "- Build the Included tickets table from the Linear ticket list above.",
            "- EVERY ticket in the Linear list MUST have its own row in the Included tickets table — including tickets with no linked PR. Never omit a ticket from the table just because it has no PR or because it also appears in a section below (e.g. 'Tickets without a PR'); those sections are IN ADDITION TO the table row, not a replacement for it. For a ticket with no PR, still add the row and set its PR(s) cell to —.",
            "- PR(s) column: render each PR URL given after a ticket ('PRs: ...') as a compact link [#<number>](<url>); if none is given, leave the cell as —.",
            "- Add a final `Dev` column (last column, after Type). Fill it with the GitHub handle(s) given after a ticket ('Devs: ...'), verbatim including the leading @ so they tag the author, comma-separated; if none is given, leave the cell as —. Column order must be: Ticket | Title | PR(s) | Type | Dev.",
            "- Map commit prefixes to Type labels per the guide (fix → Bug fix, feat → Feature, etc.).",
            "- Link tickets: [WO-N](https://linear.app/luminpdf/issue/WO-N).",
            "- Include Notes & Warnings callouts only when supported by context; never invent blocking open PRs.",
            ...(cmsTicketIds.length
                ? [
                      `- The following ticket(s) are CMS content changes, NOT code deploys: ${cmsTicketIds.join(", ")}.`,
                      "- Keep these ticket(s) in the Included tickets table above; set their Type column to `Content`.",
                  ]
                : []),
            ...(extraSections.length
                ? [
                      "- Immediately below the Included tickets table (after its `---` separator), insert the following section(s) VERBATIM — do not alter the tables, the wording, or the `- [ ]` checkboxes (they must stay clickable on GitHub):",
                      "",
                      extraSectionsMd,
                      "",
                  ]
                : []),
        ].join("\n");

        console.log(`Staging release PR ${version} (template: ${STAGING_PR_TEMPLATE})`);
        const body = runClaude(prompt, "staging release PR description");
        // Backstop: the sub-agent sometimes appends a rationale trailer despite the
        // "output only" instruction — strip any trailing "Notes on choices:" / "Notes:" block.
        const cleaned = body
            .replace(/\n+#{0,4}\s*Notes on choices:[\s\S]*$/i, "")
            .replace(/\n+#{0,4}\s*Notes:\s*\n[\s\S]*$/i, "")
            .trimEnd();
        return applyLinearReleaseUrl(cleaned, linear);
    }

    function resolveDescription(branch) {
        const headSha = run("git rev-parse HEAD");
        const cacheFile = getCachePath(branch);
        let cached = readCache(cacheFile);

        if (!cached || cached.sha !== headSha) {
            const body =
                BASE === "staging"
                    ? generateStagingDescription(branch)
                    : generateDescription();
            cached = { sha: headSha, body };
            fs.writeFileSync(cacheFile, JSON.stringify(cached));
        } else {
            console.log("No new commits — reusing cached PR description.");
        }
        return cached.body;
    }

    function withBodyFile(body, fn) {
        const bodyFile = path.join(os.tmpdir(), `pr-body-${Date.now()}.md`);
        fs.writeFileSync(bodyFile, body);
        try { return fn(bodyFile); }
        finally { fs.unlinkSync(bodyFile); }
    }

    function updateExistingPr(prUrl, bodyFile, branch) {
        console.log(`PR already exists -> ${prUrl}`);
        const title = getPrTitle(branch);
        run(`gh pr edit --base "${BASE}" --title "${title}" --add-reviewer "${REVIEWERS}" --add-label "${LABEL}" --body-file "${bodyFile}"`);
        run(`open "${prUrl}"`);
    }

    function getPrTitle(branch) {
        if (BASE === "staging") {
            const version = parseReleaseVersionFromBranch(branch);
            return `Release ${parseProductLabelFromBranch(branch, version)}`;
        }
        const ticket = branch.match(/[A-Z]+-\d+/i)?.[0]?.toUpperCase() ?? "";
        const slug = branch
            .replace(/^[^/]*\//, "")
            .replace(/[A-Z]+-\d+-?/i, "")
            .replace(/-+/g, " ")
            .trim();
        const title = slug.charAt(0).toUpperCase() + slug.slice(1);
        return `[Draft] ${ticket ? `${ticket} ` : ""}${title}`;
    }

    function createNewPr(bodyFile, branch) {
        const title = getPrTitle(branch);
        const url = run(`gh pr create --base "${BASE}" --title "${title}" --reviewer "${REVIEWERS}" --label "${LABEL}" --body-file "${bodyFile}"`);
        if (url) run(`open "${url}"`);
    }

    // --- main ---
    console.log(`\n🚀 create-pr — base: ${BASE} | reviewers: ${REVIEWERS} | label: ${LABEL}\n`);
    const branch = pushBranch();
    console.log(`📌 Branch: ${branch}`);
    const prUrl = findOpenPr(branch);
    const body = resolveDescription(branch);
    withBodyFile(body, (file) => prUrl ? updateExistingPr(prUrl, file, branch) : createNewPr(file, branch));
