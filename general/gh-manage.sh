#!/usr/bin/env bash
# gh-manage.sh — Hardened, Zero-Hardcode GitHub & Local Repo Management Toolkit

set -u
shopt -s nullglob

# Resolve workspace: defaults to current directory (.), or accepts a custom directory argument
if [ -n "${1:-}" ]; then
  if [ -d "$1" ]; then
    BASE_DIR="$(cd "$1" && pwd)"
  else
    echo "Error: Directory '$1' does not exist." >&2
    exit 1
  fi
else
  BASE_DIR="$(pwd)"
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

header() {
  echo -e "\n${CYAN}${BOLD}=== $1 ===${RESET}"
}

confirm() {
  local prompt="${1:-Are you sure?}"
  local ans=""
  read -r -p "$(echo -e "${YELLOW}${prompt} [y/N]: ${RESET}")" ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

# Silently resolve user.name and user.email from git config (with automatic gh CLI fallback)
resolve_git_identity() {
  GIT_DETECTED_NAME="$(git config --global user.name 2>/dev/null || git config user.name 2>/dev/null || true)"
  GIT_DETECTED_EMAIL="$(git config --global user.email 2>/dev/null || git config user.email 2>/dev/null || true)"

  if { [ -z "$GIT_DETECTED_NAME" ] || [ -z "$GIT_DETECTED_EMAIL" ]; } && command -v gh >/dev/null 2>&1; then
    local gh_login gh_id
    gh_login="$(gh api user -q '.login' 2>/dev/null || true)"
    gh_id="$(gh api user -q '.id' 2>/dev/null || true)"
    [ -z "$GIT_DETECTED_NAME" ] && [ -n "$gh_login" ] && GIT_DETECTED_NAME="$gh_login"
    [ -z "$GIT_DETECTED_EMAIL" ] && [ -n "$gh_login" ] && [ -n "$gh_id" ] && GIT_DETECTED_EMAIL="${gh_id}+${gh_login}@users.noreply.github.com"
  fi

  if [ -z "$GIT_DETECTED_NAME" ] || [ -z "$GIT_DETECTED_EMAIL" ]; then
    echo -e "${RED}Error: user.name or user.email is missing in git config. Use Module 1 to set them first.${RESET}" >&2
    return 1
  fi
  return 0
}

# Dynamically detect authenticated GitHub username from gh CLI
get_gh_user() {
  if command -v gh >/dev/null 2>&1; then
    gh api user -q '.login' 2>/dev/null || true
  fi
}

# Safely resolve current branch name (supports unborn repos with 0 commits)
get_current_branch() {
  local repo_path="$1"
  local branch
  branch="$(git -C "$repo_path" symbolic-ref --short HEAD 2>/dev/null || true)"
  echo "$branch"
}

# Gather target repo paths (BASE_DIR itself if it's a git repo, plus all immediate child repos)
get_target_repos() {
  TARGET_REPOS=()
  [ -d "${BASE_DIR}/.git" ] && TARGET_REPOS+=("$BASE_DIR")
  for d in "$BASE_DIR"/*/; do
    [ -d "${d}.git" ] && TARGET_REPOS+=("${d%/}")
  done
}

# Select a single repo or ALL repos (sets SELECTED_REPOS array)
select_repos() {
  local allow_all="${1:-yes}"
  get_target_repos
  SELECTED_REPOS=()

  if [ ${#TARGET_REPOS[@]} -eq 0 ]; then
    echo -e "${RED}No git repositories found in $BASE_DIR${RESET}" >&2
    return 1
  fi

  echo -e "${BOLD}Available repositories in $BASE_DIR:${RESET}" >&2
  local i=1
  for r in "${TARGET_REPOS[@]}"; do
    local dirty_count dirty_tag=""
    dirty_count="$(git -C "$r" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
    [ "$dirty_count" -gt 0 ] && dirty_tag=" ${YELLOW}[${dirty_count} uncommitted]${RESET}"

    if [ "$r" = "$BASE_DIR" ]; then
      printf "  %2d) . (current directory: %s)%b\n" "$i" "$(basename "$BASE_DIR")" "$dirty_tag" >&2
    else
      printf "  %2d) %s%b\n" "$i" "$(basename "$r")" "$dirty_tag" >&2
    fi
    ((i++))
  done
  if [ "$allow_all" = "yes" ] && [ ${#TARGET_REPOS[@]} -gt 1 ]; then
    printf "   A) ALL (%d repositories)\n" "${#TARGET_REPOS[@]}" >&2
  fi

  local choice=""
  read -r -p "Select target: " choice
  if [ "$allow_all" = "yes" ] && [[ "$choice" =~ ^[Aa]$ ]]; then
    SELECTED_REPOS=("${TARGET_REPOS[@]}")
    return 0
  elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#TARGET_REPOS[@]}" ]; then
    SELECTED_REPOS=("${TARGET_REPOS[$((choice-1))]}")
    return 0
  else
    echo -e "${RED}Invalid selection.${RESET}" >&2
    return 1
  fi
}

# Core helper: collapse a single repo path to 1 orphan commit using config identity
wipe_single_repo() {
  local repo_path="$1"
  local msg="$2"
  local repo_name branch
  repo_name="$(basename "$repo_path")"
  branch="$(get_current_branch "$repo_path")"

  if [ -z "$branch" ]; then
    echo -e "${RED}[SKIP] $repo_name is in detached HEAD state.${RESET}"
    return 1
  fi

  (
    cd "$repo_path" || exit 1
    git config --local --unset-all user.name 2>/dev/null || true
    git config --local --unset-all user.email 2>/dev/null || true
    git stash clear 2>/dev/null || true

    git checkout --orphan temp_clean >/dev/null 2>&1 || exit 1
    git add -A
    GIT_AUTHOR_NAME="$GIT_DETECTED_NAME" \
    GIT_AUTHOR_EMAIL="$GIT_DETECTED_EMAIL" \
    GIT_COMMITTER_NAME="$GIT_DETECTED_NAME" \
    GIT_COMMITTER_EMAIL="$GIT_DETECTED_EMAIL" \
    git commit --allow-empty -m "$msg" >/dev/null || exit 1

    git branch -D "$branch" >/dev/null 2>&1 || true
    git branch -m "$branch"

    if git remote get-url origin >/dev/null 2>&1; then
      git push -f -u origin "$branch"
      git remote set-head origin "$branch" 2>/dev/null || true
      git fetch --prune origin >/dev/null 2>&1 || true
    fi

    git reflog expire --expire=now --all
    git gc --aggressive --prune=all >/dev/null 2>&1
  ) && echo -e "${GREEN}[OK] $repo_name -> 1 clean commit on '$branch' (${GIT_DETECTED_NAME} <${GIT_DETECTED_EMAIL}>)${RESET}" \
    || echo -e "${RED}[FAIL] $repo_name encountered an error.${RESET}"
}

# Core helper: rewrite author/committer metadata while preserving commit timeline
rewrite_single_repo() {
  local repo_path="$1"
  local repo_name
  repo_name="$(basename "$repo_path")"

  if ! git -C "$repo_path" rev-parse HEAD >/dev/null 2>&1; then
    echo -e "${YELLOW}[SKIP] $repo_name has no commits yet.${RESET}"
    return 0
  fi

  (
    cd "$repo_path" || exit 1
    git config --local --unset-all user.name 2>/dev/null || true
    git config --local --unset-all user.email 2>/dev/null || true
    rm -rf .git/refs/original/

    FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch -f --env-filter "
      export GIT_AUTHOR_NAME=\"$GIT_DETECTED_NAME\"
      export GIT_AUTHOR_EMAIL=\"$GIT_DETECTED_EMAIL\"
      export GIT_COMMITTER_NAME=\"$GIT_DETECTED_NAME\"
      export GIT_COMMITTER_EMAIL=\"$GIT_DETECTED_EMAIL\"
    " --tag-name-filter cat -- --all >/dev/null || exit 1

    rm -rf .git/refs/original/
    git reflog expire --expire=now --all
    git gc --aggressive --prune=all >/dev/null 2>&1

    if git remote get-url origin >/dev/null 2>&1; then
      git push -f origin --all
      git push -f origin --tags
    fi
  ) && echo -e "${GREEN}[OK] $repo_name -> Metadata normalized to ${GIT_DETECTED_NAME} <${GIT_DETECTED_EMAIL}>${RESET}" \
    || echo -e "${RED}[FAIL] $repo_name encountered an error.${RESET}"
}

# Helper for Module 10: Clone missing + pull existing repos filtered by visibility (public|private|all)
gh_clone_and_pull_by_visibility() {
  local vis="$1"
  local args=(--limit 1000 --json nameWithOwner -q '.[].nameWithOwner')
  [ "$vis" != "all" ] && args=(--visibility "$vis" "${args[@]}")

  local slugs=()
  mapfile -t slugs < <(gh repo list "${args[@]}")

  if [ ${#slugs[@]} -eq 0 ]; then
    echo -e "${YELLOW}No ${vis} repositories found on GitHub.${RESET}"
    return
  fi

  echo -e "${BOLD}Found ${#slugs[@]} ${vis} repository(s):${RESET}"
  printf '  - %s\n' "${slugs[@]}"
  echo ""

  if ! confirm "Clone missing and fast-forward pull existing ${vis} repos into $BASE_DIR?"; then
    return
  fi

  for slug in "${slugs[@]}"; do
    local name target branch
    name="$(basename "$slug")"
    target="$BASE_DIR/$name"
    if [ -d "$target/.git" ]; then
      branch="$(get_current_branch "$target")"
      echo -e "${CYAN}[PULL]${RESET} $slug ($branch)..."
      git -C "$target" pull --ff-only origin "$branch" || echo -e "${YELLOW}[WARN] Could not fast-forward $name (local divergence).${RESET}"
    elif [ ! -e "$target" ]; then
      echo -e "${GREEN}[CLONE]${RESET} $slug..."
      (cd "$BASE_DIR" && gh repo clone "$slug")
    else
      echo -e "${YELLOW}[SKIP]${RESET} $target exists and is not a git repo."
    fi
  done
}

# Helper for Module 10: Delete single repo on remote + local
gh_delete_one_repo() {
  local slug="$1"
  local repo_dir="$BASE_DIR/$(basename "$slug")"
  [ "$(basename "$BASE_DIR")" = "$(basename "$slug")" ] && [ -d "$BASE_DIR/.git" ] && repo_dir="$BASE_DIR"

  if gh repo delete "$slug" --yes >/dev/null 2>&1; then
    echo -e "${GREEN}[REMOTE DELETED]${RESET} $slug"
  else
    echo -e "${YELLOW}[RETRY]${RESET} Unarchiving $slug first..."
    if gh repo unarchive "$slug" --yes >/dev/null 2>&1 && gh repo delete "$slug" --yes >/dev/null 2>&1; then
      echo -e "${GREEN}[REMOTE DELETED]${RESET} $slug"
    else
      echo -e "${RED}[REMOTE FAIL]${RESET} Could not delete $slug on GitHub."
      return 1
    fi
  fi

  if [ -d "$repo_dir" ] && [ "$repo_dir" != "/" ] && [ "$repo_dir" != "$HOME" ]; then
    rm -rf "$repo_dir"
    echo -e "${GREEN}[LOCAL DELETED]${RESET} $repo_dir"
  fi
}

# Helper for Module 10: Bulk delete public or private repos with exception list & preview
gh_bulk_delete_by_visibility() {
  local vis="$1"
  local slugs=()
  mapfile -t slugs < <(gh repo list --visibility "$vis" --limit 1000 --json nameWithOwner -q '.[].nameWithOwner')

  if [ ${#slugs[@]} -eq 0 ]; then
    echo -e "${YELLOW}No ${vis} repositories found on GitHub.${RESET}"
    return
  fi

  echo -e "${BOLD}All ${vis} repositories (${#slugs[@]}):${RESET}"
  printf '  - %s\n' "${slugs[@]}"
  echo ""

  local exclude_input=""
  read -r -p "Comma-separated repo names to KEEP/EXCLUDE (or Enter to target ALL): " exclude_input

  local to_delete=()
  for slug in "${slugs[@]}"; do
    local short_name skip=0
    short_name="$(basename "$slug")"
    if [ -n "$exclude_input" ]; then
      IFS=',' read -ra excl_arr <<< "$exclude_input"
      for ex in "${excl_arr[@]}"; do
        ex="$(echo "$ex" | xargs)"
        [ -z "$ex" ] && continue
        if [ "$slug" = "$ex" ] || [ "$short_name" = "$ex" ]; then
          skip=1
          break
        fi
      done
    fi
    [ "$skip" -eq 0 ] && to_delete+=("$slug")
  done

  if [ ${#to_delete[@]} -eq 0 ]; then
    echo -e "${GREEN}Nothing left to delete after exclusions.${RESET}"
    return
  fi

  echo -e "\n${RED}${BOLD}DRY RUN — The following ${#to_delete[@]} ${vis} repository(s) will be PERMANENTLY deleted (Remote + Local):${RESET}"
  printf '  * %s\n' "${to_delete[@]}"
  echo ""

  if ! confirm "PERMANENTLY delete all ${#to_delete[@]} listed ${vis} repositories on GitHub AND locally?"; then
    echo "Cancelled."
    return
  fi

  for slug in "${to_delete[@]}"; do
    gh_delete_one_repo "$slug"
  done
}

# 1. Manage Git Identity (Auto-Sync from gh CLI OR Add/Update Manually)
mod_git_identity() {
  header "1. Git Identity Manager (Config / GitHub CLI / Manual)"
  local cur_name cur_email gh_login gh_id noreply_email opt in_name in_email
  cur_name="$(git config --global user.name 2>/dev/null || true)"
  cur_email="$(git config --global user.email 2>/dev/null || true)"

  echo "Current global config:"
  echo "  user.name  = ${cur_name:-(not set)}"
  echo "  user.email = ${cur_email:-(not set)}"
  echo ""
  echo "  1) Auto-sync from active GitHub CLI (gh) account"
  echo "  2) Add / edit custom global user.name & user.email"
  echo "  3) Set custom local user.name & user.email for a specific repo"
  echo "  0) Back"
  read -r -p "Choose option [0-3]: " opt

  case "$opt" in
    1)
      if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
        gh_login="$(gh api user -q '.login' 2>/dev/null || true)"
        gh_id="$(gh api user -q '.id' 2>/dev/null || true)"
        if [ -n "$gh_login" ] && [ -n "$gh_id" ]; then
          noreply_email="${gh_id}+${gh_login}@users.noreply.github.com"
          git config --global user.name "$gh_login"
          git config --global user.email "$noreply_email"
          echo -e "${GREEN}Global identity synced to: ${gh_login} <${noreply_email}>${RESET}"
        else
          echo -e "${RED}Could not fetch user details from GitHub API.${RESET}"
        fi
      else
        echo -e "${RED}GitHub CLI (gh) is not installed or not authenticated.${RESET}"
      fi
      ;;
    2)
      read -r -p "Enter user.name  [Enter to keep '${cur_name}']: " in_name
      read -r -p "Enter user.email [Enter to keep '${cur_email}']: " in_email
      in_name="${in_name:-$cur_name}"
      in_email="${in_email:-$cur_email}"
      [ -n "$in_name" ] && git config --global user.name "$in_name"
      [ -n "$in_email" ] && git config --global user.email "$in_email"
      echo -e "${GREEN}Global identity updated: $(git config --global user.name) <$(git config --global user.email)>${RESET}"
      ;;
    3)
      select_repos "no" || return
      local target_repo="${SELECTED_REPOS[0]}"
      read -r -p "Enter local user.name:  " in_name
      read -r -p "Enter local user.email: " in_email
      [ -n "$in_name" ] && git -C "$target_repo" config --local user.name "$in_name"
      [ -n "$in_email" ] && git -C "$target_repo" config --local user.email "$in_email"
      echo -e "${GREEN}Local identity set for $(basename "$target_repo"): ${in_name} <${in_email}>${RESET}"
      ;;
    *) return ;;
  esac
}

# 2. Full Audit of Repositories
mod_audit_all() {
  header "2. Full Audit of Repositories in $BASE_DIR"
  get_target_repos
  if [ ${#TARGET_REPOS[@]} -eq 0 ]; then
    echo -e "${RED}No git repositories found in $BASE_DIR${RESET}"
    return
  fi

  resolve_git_identity || true
  if [ -n "${GIT_DETECTED_NAME:-}" ] && [ -n "${GIT_DETECTED_EMAIL:-}" ]; then
    echo -e "Config identity: ${BOLD}${GIT_DETECTED_NAME} <${GIT_DETECTED_EMAIL}>${RESET}"
  fi

  read -r -p "Optional regex to scan commit headers/messages [Enter to skip]: " pattern

  printf "\n${BOLD}%-26s | %-7s | %-5s | %-18s | %s${RESET}\n" "REPOSITORY" "COMMITS" "DIRTY" "REMOTE SYNC" "IDENTITIES"
  printf -- "--------------------------------------------------------------------------------------------------------\n"

  local mismatch_count=0
  for d in "${TARGET_REPOS[@]}"; do
    local repo commits dirty ident branch local_sha remote_sha sync_status
    repo="$(basename "$d")"
    commits="$(git -C "$d" rev-list --all --count 2>/dev/null || echo "0")"
    dirty="$(git -C "$d" status --porcelain | wc -l | tr -d ' ')"
    ident="$(git -C "$d" log --all --format='%an <%ae>' 2>/dev/null | sort -u | tr '\n' ';' | sed 's/;$//')"

    git -C "$d" fetch --prune origin >/dev/null 2>&1 || true
    branch="$(get_current_branch "$d")"
    local_sha="$(git -C "$d" rev-parse HEAD 2>/dev/null || echo "")"
    remote_sha="$(git -C "$d" rev-parse "origin/$branch" 2>/dev/null || echo "")"

    if ! git -C "$d" remote get-url origin >/dev/null 2>&1; then
      sync_status="NO_REMOTE"
    elif [ "$dirty" -gt 0 ]; then
      sync_status="DIRTY(${dirty})"
    elif [ -n "$local_sha" ] && [ -n "$remote_sha" ] && [ "$local_sha" = "$remote_sha" ]; then
      sync_status="SYNCED(${local_sha:0:7})"
    else
      sync_status="MISMATCH"
    fi

    printf "%-26s | %-7s | %-5s | %-18s | %s\n" "$repo" "$commits" "$dirty" "$sync_status" "${ident:-(no commits)}"

    if [ -n "$ident" ] && [ -n "${GIT_DETECTED_NAME:-}" ] && [ -n "${GIT_DETECTED_EMAIL:-}" ] && [ "$ident" != "${GIT_DETECTED_NAME} <${GIT_DETECTED_EMAIL}>" ]; then
      ((mismatch_count++))
    fi
  done

  if [ "$mismatch_count" -gt 0 ]; then
    echo -e "\n${YELLOW}Note: ${mismatch_count} repo(s) have commit identities differing from your git config.${RESET}"
  elif [ -n "${GIT_DETECTED_NAME:-}" ]; then
    echo -e "\n${GREEN}All repositories match your git config identity.${RESET}"
  fi

  if [ -n "$pattern" ]; then
    echo -e "\n${BOLD}Scanning commit headers/messages for pattern: ${pattern}${RESET}"
    local found=0
    for d in "${TARGET_REPOS[@]}"; do
      local matches
      matches="$(git -C "$d" log --all --format="%h | %an <%ae> | %cn <%ce> | %s" 2>/dev/null | grep -iE "$pattern" || true)"
      if [ -n "$matches" ]; then
        echo -e "${RED}Match in $(basename "$d"):${RESET}"
        echo "$matches"
        found=1
      fi
    done
    [ "$found" -eq 0 ] && echo -e "${GREEN}Zero matches found across all repositories.${RESET}"
  fi
}

# 3. Quick Add, Commit & Push (git add -A && git commit && git push origin)
mod_quick_commit_push() {
  header "3. Quick Add, Commit & Push (add -A -> commit -> push origin)"
  select_repos "yes" || return

  local default_msg=""
  if [ ${#SELECTED_REPOS[@]} -gt 1 ]; then
    read -r -p "Commit message for all dirty repos [Update files]: " default_msg
    default_msg="${default_msg:-Update files}"
  fi

  for repo_path in "${SELECTED_REPOS[@]}"; do
    local repo_name branch dirty_count msg has_remote has_commits
    repo_name="$(basename "$repo_path")"
    branch="$(get_current_branch "$repo_path")"

    if [ -z "$branch" ]; then
      echo -e "${RED}[SKIP] $repo_name is in detached HEAD state.${RESET}"
      continue
    fi

    has_remote=0
    git -C "$repo_path" remote get-url origin >/dev/null 2>&1 && has_remote=1
    has_commits=0
    git -C "$repo_path" rev-parse HEAD >/dev/null 2>&1 && has_commits=1

    dirty_count="$(git -C "$repo_path" status --porcelain | wc -l | tr -d ' ')"
    if [ "$dirty_count" -eq 0 ]; then
      if [ "$has_commits" -eq 1 ] && [ "$has_remote" -eq 1 ]; then
        local remote_exists ahead_count
        remote_exists="$(git -C "$repo_path" rev-parse --verify "origin/${branch}" 2>/dev/null || echo "")"
        if [ -z "$remote_exists" ]; then
          echo -e "${CYAN}[PUSH NEW BRANCH]${RESET} $repo_name -> pushing '$branch' to origin..."
          git -C "$repo_path" push -u origin "$branch" \
            && echo -e "${GREEN}[OK] Pushed $repo_name to origin/$branch${RESET}" \
            || echo -e "${RED}[FAIL] Could not push $repo_name${RESET}"
          continue
        fi
        ahead_count="$(git -C "$repo_path" rev-list --count "origin/${branch}..HEAD" 2>/dev/null || echo "0")"
        if [ "$ahead_count" -gt 0 ]; then
          echo -e "${CYAN}[PUSH ONLY]${RESET} $repo_name has $ahead_count unpushed commit(s) on '$branch'."
          git -C "$repo_path" push -u origin "$branch" \
            && echo -e "${GREEN}[OK] Pushed $repo_name to origin/$branch${RESET}" \
            || echo -e "${RED}[FAIL] Could not push $repo_name${RESET}"
          continue
        fi
      fi
      echo -e "${YELLOW}[SKIP]${RESET} $repo_name has no uncommitted or unpushed changes."
      continue
    fi

    echo -e "\n${BOLD}Repository:${RESET} $repo_name ($branch) — ${YELLOW}$dirty_count file(s) changed${RESET}"
    git -C "$repo_path" status -s

    if [ -n "$default_msg" ]; then
      msg="$default_msg"
    else
      read -r -p "Enter commit message [Update files]: " msg
      msg="${msg:-Update files}"
    fi

    git -C "$repo_path" add -A
    if git -C "$repo_path" commit -m "$msg"; then
      if [ "$has_remote" -eq 1 ]; then
        git -C "$repo_path" push -u origin "$branch" \
          && echo -e "${GREEN}[OK] $repo_name committed & pushed to origin/$branch${RESET}" \
          || echo -e "${RED}[FAIL] Committed locally, but push to origin/$branch failed.${RESET}"
      else
        echo -e "${YELLOW}[OK] $repo_name committed locally (no 'origin' remote configured).${RESET}"
      fi
    else
      echo -e "${RED}[FAIL] Commit failed in $repo_name.${RESET}"
    fi
  done
}

# 4. Sync / Pull / Force-Push Repositories with Remote
mod_sync_all() {
  header "4. Sync Repositories with Remote"
  get_target_repos
  if [ ${#TARGET_REPOS[@]} -eq 0 ]; then
    echo -e "${RED}No git repositories found in $BASE_DIR${RESET}"
    return
  fi

  echo "  1) Check & Push / Force-Push local HEAD to origin on mismatch"
  echo "  2) Fast-forward Pull (git pull --ff-only) across all local repos"
  local mode=""
  read -r -p "Choose sync mode [1-2]: " mode

  for d in "${TARGET_REPOS[@]}"; do
    local repo branch local_sha remote_sha dirty_count
    repo="$(basename "$d")"
    git -C "$d" remote get-url origin >/dev/null 2>&1 || continue
    git -C "$d" fetch --prune origin >/dev/null 2>&1 || true
    branch="$(get_current_branch "$d")"
    [ -z "$branch" ] && continue
    local_sha="$(git -C "$d" rev-parse HEAD 2>/dev/null || echo "")"
    remote_sha="$(git -C "$d" rev-parse "origin/$branch" 2>/dev/null || echo "")"
    dirty_count="$(git -C "$d" status --porcelain | wc -l | tr -d ' ')"

    if [ "$mode" = "2" ]; then
      if [ "$dirty_count" -gt 0 ]; then
        printf "%-26s | ${YELLOW}SKIPPED (%s uncommitted file(s) — commit or stash first)${RESET}\n" "$repo" "$dirty_count"
      elif [ -z "$remote_sha" ]; then
        printf "%-26s | ${YELLOW}SKIPPED (origin/%s does not exist)${RESET}\n" "$repo" "$branch"
      else
        printf "%-26s | " "$repo"
        git -C "$d" pull --ff-only origin "$branch"
      fi
    else
      if [ "$dirty_count" -gt 0 ]; then
        printf "%-26s | %-6s | ${YELLOW}UNCOMMITTED (%s file(s) modified — run Module 3 first)${RESET}\n" "$repo" "$branch" "$dirty_count"
      elif [ -z "$local_sha" ]; then
        printf "%-26s | %-6s | ${YELLOW}NO COMMITS YET${RESET}\n" "$repo" "$branch"
      elif [ -z "$remote_sha" ]; then
        printf "%-26s | %-6s | ${YELLOW}NO REMOTE BRANCH (origin/%s missing)${RESET}\n" "$repo" "$branch" "$branch"
        if confirm "Push local $branch to origin for $repo?"; then
          git -C "$d" push -u origin "$branch"
        fi
      elif [ "$local_sha" = "$remote_sha" ]; then
        printf "%-26s | %-6s | ${GREEN}SYNCED (%s)${RESET}\n" "$repo" "$branch" "${local_sha:0:7}"
      else
        printf "%-26s | %-6s | ${YELLOW}MISMATCH (local: %s, remote: %s)${RESET}\n" "$repo" "$branch" "${local_sha:0:7}" "${remote_sha:0:7}"
        if confirm "Force-push local $branch to origin for $repo?"; then
          git -C "$d" push -f origin "$branch"
        fi
      fi
    fi
  done
}

# 5. Wipe Commit History (Single or Batch Orphan Commit)
mod_wipe_history() {
  header "5. Wipe Repo History to Single Orphan Commit"
  resolve_git_identity || return
  select_repos "yes" || return

  echo -e "${YELLOW}Identity (from config):${RESET} $GIT_DETECTED_NAME <$GIT_DETECTED_EMAIL>"
  echo -e "${YELLOW}Targets:${RESET}                ${#SELECTED_REPOS[@]} repository(s)"
  if ! confirm "Collapse ALL commits in the selected repo(s) into 1 initial commit and force-push?"; then
    return
  fi

  local msg=""
  read -r -p "Commit message [Initial commit]: " msg
  msg="${msg:-Initial commit}"

  for repo_path in "${SELECTED_REPOS[@]}"; do
    wipe_single_repo "$repo_path" "$msg"
  done
}

# 6. Rewrite Author/Committer Metadata (Single or Batch, Preserve Timeline)
mod_rewrite_metadata() {
  header "6. Rewrite Author/Committer Metadata (Preserve Timeline)"
  resolve_git_identity || return
  select_repos "yes" || return

  echo -e "${YELLOW}Identity (from config):${RESET} $GIT_DETECTED_NAME <$GIT_DETECTED_EMAIL>"
  echo -e "${YELLOW}Targets:${RESET}                ${#SELECTED_REPOS[@]} repository(s)"
  if ! confirm "Rewrite all commit author/committer fields in selected repo(s) and force-push?"; then
    return
  fi

  for repo_path in "${SELECTED_REPOS[@]}"; do
    rewrite_single_repo "$repo_path"
  done
}

# 7. Remove a Specific Commit (Reset HEAD~1 or Interactive Rebase)
mod_remove_specific_commit() {
  header "7. Remove a Specific Commit"
  select_repos "no" || return
  local repo_path="${SELECTED_REPOS[0]}"

  (
    cd "$repo_path" || exit 1
    echo -e "${BOLD}Recent commits in $(basename "$repo_path"):${RESET}"
    git log --oneline -n 15
    echo ""
    echo "  1) Remove latest commit (git reset --hard HEAD~1)"
    echo "  2) Interactive rebase to drop an older commit (git rebase -i)"
    local sub=""
    read -r -p "Choose action [1-2]: " sub
    case "$sub" in
      1)
        if confirm "Hard-reset HEAD~1 and force-push?"; then
          local branch
          branch="$(get_current_branch "$repo_path")"
          git reset --hard HEAD~1
          git push -f origin "$branch"
          git reflog expire --expire=now --all
          git gc --aggressive --prune=all
        fi
        ;;
      2)
        local hash="" branch
        read -r -p "Enter target commit hash to drop (or 'root' for first commit): " hash
        [ -z "$hash" ] && return
        branch="$(get_current_branch "$repo_path")"
        if [ "$hash" = "root" ]; then
          git rebase -i --root
        else
          git rebase -i "${hash}^"
        fi
        if confirm "Force-push rebased history to origin/$branch?"; then
          git push -f origin "$branch"
          git reflog expire --expire=now --all
          git gc --aggressive --prune=all
        fi
        ;;
      *) echo "Cancelled." ;;
    esac
  )
}

# 8. Safe Search & Literal Replace Across Files (Python-backed, delimiter-safe)
mod_grep_replace_files() {
  header "8. Search & Replace Strings in Repo Files"
  local search_re=""
  read -r -p "Enter search regex: " search_re
  [ -z "$search_re" ] && return

  echo -e "\n${BOLD}Matches found in $BASE_DIR (excluding .git):${RESET}"
  grep -rniE --exclude-dir=".git" "$search_re" "$BASE_DIR" || {
    echo -e "${GREEN}No matches found.${RESET}"
    return
  }

  echo ""
  if confirm "Run an exact literal string replacement across selected repo(s)?"; then
    select_repos "yes" || return
    local find_str="" repl_str=""
    read -r -p "Exact string to find: " find_str
    read -r -p "Replacement string:   " repl_str
    [ -z "$find_str" ] && return

    for repo_path in "${SELECTED_REPOS[@]}"; do
      python3 - "$repo_path" "$find_str" "$repl_str" <<'PY'
import os, sys

root, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
for dirpath, dirnames, filenames in os.walk(root):
    if ".git" in dirnames:
        dirnames.remove(".git")
    for fn in filenames:
        fp = os.path.join(dirpath, fn)
        try:
            with open(fp, "rb") as f:
                raw = f.read()
            if b"\x00" in raw:
                continue
            text = raw.decode("utf-8")
            if old in text:
                with open(fp, "w", encoding="utf-8") as f:
                    f.write(text.replace(old, new))
                print(f"Updated: {fp}")
        except Exception:
            pass
PY
    done
    echo -e "${GREEN}Replacement complete. Review changes with 'git diff'.${RESET}"
  fi
}

# 9. Branch, Tag, Stash & GC Deep Purge
mod_cleanup_refs() {
  header "9. Purge Stale Branches, Tags, Stashes & Run GC"
  select_repos "yes" || return

  echo "  1) Prune remote-tracking branches + expire reflog + aggressive GC"
  echo "  2) Delete ALL local & remote tags (Warning: irreversible)"
  echo "  3) Delete all local branches except current active branch"
  local opt=""
  read -r -p "Choose cleanup action [1-3]: " opt

  for repo_path in "${SELECTED_REPOS[@]}"; do
    local repo_name branch
    repo_name="$(basename "$repo_path")"
    branch="$(get_current_branch "$repo_path")"
    case "$opt" in
      1)
        (
          cd "$repo_path" || exit 1
          git stash clear 2>/dev/null || true
          git fetch --prune origin 2>/dev/null || true
          git reflog expire --expire=now --all
          git gc --aggressive --prune=all >/dev/null 2>&1
        )
        echo -e "${GREEN}[GC OK] $repo_name${RESET}"
        ;;
      2)
        if confirm "Delete ALL local and remote tags in $repo_name?"; then
          (
            cd "$repo_path" || exit 1
            while IFS= read -r t; do
              [ -z "$t" ] && continue
              git push origin ":refs/tags/$t" 2>/dev/null || true
              git tag -d "$t" >/dev/null
            done < <(git tag)
          )
          echo -e "${GREEN}[TAGS PURGED] $repo_name${RESET}"
        fi
        ;;
      3)
        if confirm "Delete all local branches except '$branch' in $repo_name?"; then
          (
            cd "$repo_path" || exit 1
            while IFS= read -r b; do
              [ -n "$b" ] && [ "$b" != "$branch" ] && git branch -D "$b"
            done < <(git for-each-ref --format='%(refname:short)' refs/heads/)
          )
          echo -e "${GREEN}[BRANCHES CLEANED] $repo_name${RESET}"
        fi
        ;;
    esac
  done
}

# 10. GitHub CLI Operations (Public / Private / Specific Clone, Pull, Archive & Delete)
mod_github_cli() {
  header "10. GitHub CLI Repository & Gist Manager"
  if ! command -v gh >/dev/null 2>&1; then
    echo -e "${RED}Error: 'gh' CLI is not installed.${RESET}"
    return
  fi

  local gh_owner
  gh_owner="$(get_gh_user)"
  [ -n "$gh_owner" ] && echo -e "Authenticated GitHub account: ${BOLD}${gh_owner}${RESET}"

  echo ""
  echo -e "${BOLD}List & Inspect:${RESET}"
  echo "   1) List PRIVATE repositories"
  echo "   2) List PUBLIC repositories"
  echo "   3) List ALL repositories (public + private)"
  echo "   4) List Gists"
  echo -e "${BOLD}Clone & Pull into ${BASE_DIR}:${RESET}"
  echo "   5) Clone / Pull a SPECIFIC repository"
  echo "   6) Clone / Pull ALL PRIVATE repositories"
  echo "   7) Clone / Pull ALL PUBLIC repositories"
  echo "   8) Clone / Pull ALL repositories (public + private)"
  echo -e "${BOLD}Archive & Delete (Remote + Local):${RESET}"
  echo "   9) Unarchive -> Force-Push -> Re-archive a specific repository"
  echo "  10) Delete a SPECIFIC repository (Remote + Local)"
  echo "  11) Delete ALL PRIVATE repositories (with optional keep-list)"
  echo "  12) Delete ALL PUBLIC repositories (with optional keep-list)"
  echo "   0) Back"
  echo ""
  local opt=""
  read -r -p "Choose option [0-12]: " opt

  case "$opt" in
    1) gh repo list --visibility private --limit 1000 ;;
    2) gh repo list --visibility public --limit 1000 ;;
    3) gh repo list --limit 1000 ;;
    4) gh gist list ;;
    5)
      local slug="" target branch
      read -r -p "Enter repo name or owner/repo: " slug
      [ -z "$slug" ] && return
      [[ "$slug" != */* && -n "$gh_owner" ]] && slug="${gh_owner}/${slug}"
      target="$BASE_DIR/$(basename "$slug")"
      if [ -d "$target/.git" ]; then
        branch="$(get_current_branch "$target")"
        echo -e "${CYAN}[PULL]${RESET} $slug ($branch)..."
        git -C "$target" pull --ff-only origin "$branch"
      else
        (cd "$BASE_DIR" && gh repo clone "$slug")
      fi
      ;;
    6) gh_clone_and_pull_by_visibility "private" ;;
    7) gh_clone_and_pull_by_visibility "public" ;;
    8) gh_clone_and_pull_by_visibility "all" ;;
    9)
      local slug="" repo_dir branch
      read -r -p "Enter repo name or owner/repo: " slug
      [ -z "$slug" ] && return
      [[ "$slug" != */* && -n "$gh_owner" ]] && slug="${gh_owner}/${slug}"
      repo_dir="$BASE_DIR/$(basename "$slug")"
      [ "$(basename "$BASE_DIR")" = "$(basename "$slug")" ] && [ -d "$BASE_DIR/.git" ] && repo_dir="$BASE_DIR"
      if [ -d "$repo_dir/.git" ] && confirm "Unarchive $slug, force-push local HEAD, and re-archive?"; then
        gh repo unarchive "$slug" --yes
        branch="$(get_current_branch "$repo_dir")"
        git -C "$repo_dir" push -f origin "$branch"
        gh repo archive "$slug" --yes
      else
        echo -e "${RED}Local directory $repo_dir not found or cancelled.${RESET}"
      fi
      ;;
    10)
      local slug=""
      read -r -p "Enter repo name or owner/repo to PERMANENTLY delete: " slug
      [ -z "$slug" ] && return
      [[ "$slug" != */* && -n "$gh_owner" ]] && slug="${gh_owner}/${slug}"
      if confirm "PERMANENTLY delete $slug on GitHub AND locally?"; then
        gh_delete_one_repo "$slug"
      fi
      ;;
    11) gh_bulk_delete_by_visibility "private" ;;
    12) gh_bulk_delete_by_visibility "public" ;;
    *) return ;;
  esac
}

# 11. Change Workspace Directory
mod_change_dir() {
  header "11. Change Workspace Directory"
  echo -e "Current workspace: ${BOLD}${BASE_DIR}${RESET}"
  local new_dir=""
  read -r -p "Enter new directory path (supports ~ or relative paths): " new_dir
  [ -z "$new_dir" ] && return
  new_dir="${new_dir/#\~/$HOME}"
  if [ -d "$new_dir" ]; then
    BASE_DIR="$(cd "$new_dir" && pwd)"
    echo -e "${GREEN}Workspace switched to: ${BASE_DIR}${RESET}"
  else
    echo -e "${RED}Directory not found: ${new_dir}${RESET}"
  fi
}

# Main Interactive Menu
while true; do
  resolve_git_identity >/dev/null 2>&1 || true
  active_id="${GIT_DETECTED_NAME:-unset} <${GIT_DETECTED_EMAIL:-unset}>"
  header "GitHub & Git Maintenance Suite"
  echo -e "Workspace (.) : ${BOLD}${BASE_DIR}${RESET}"
  echo -e "Config ID     : ${GREEN}${active_id}${RESET}\n"
  echo "   1) Manage Git Identity (Auto-Sync gh OR Add/Edit Custom)"
  echo "   2) Audit Repositories (Commits, Dirty, Sync, Identity Match)"
  echo "   3) Quick Add, Commit & Push (git add -A -> commit -> push)"
  echo "   4) Sync Repositories with Remote (Force-Push or FF-Pull)"
  echo "   5) Wipe Repo Commit History (Single or Batch Orphan Commit)"
  echo "   6) Rewrite Author/Committer Metadata (Single or Batch)"
  echo "   7) Remove a Specific Commit (HEAD~1 or Rebase Drop)"
  echo "   8) Safe Search & Literal Replace in Repo Files"
  echo "   9) Purge Stale Branches, Tags, Stashes & Run GC"
  echo "  10) GitHub CLI Manager (Public/Private Clone, Pull & Delete)"
  echo "  11) Change Workspace Directory (Currently: .)"
  echo "   0) Exit"
  echo ""
  choice=""
  read -r -p "Select module [0-11]: " choice

  case "$choice" in
    1) mod_git_identity ;;
    2) mod_audit_all ;;
    3) mod_quick_commit_push ;;
    4) mod_sync_all ;;
    5) mod_wipe_history ;;
    6) mod_rewrite_metadata ;;
    7) mod_remove_specific_commit ;;
    8) mod_grep_replace_files ;;
    9) mod_cleanup_refs ;;
    10) mod_github_cli ;;
    11) mod_change_dir ;;
    0) echo "Exiting."; exit 0 ;;
    *) echo -e "${RED}Invalid option.${RESET}" ;;
  esac
done
