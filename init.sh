#!/usr/bin/env bash
# Init - Pick a category, then pick a script to run
#
# i - small shell scripts by psvim  (psv.im/i)
# First choose a category, then choose a script from it. Shows 8 scripts per
# page within a category. Press n for next page, p for previous, b for back
# to categories, q to quit. Set PAGE_SIZE to change it, e.g.:
#   PAGE_SIZE=12 bash <(curl -fsSL psv.im/i/init.sh)

REPO="psvim/i"
BRANCH="main"
PAGE_SIZE="${PAGE_SIZE:-8}"
TARBALL="https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz"

case "$PAGE_SIZE" in ''|*[!0-9]*|0) PAGE_SIZE=8 ;; esac

for cmd in curl tar; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Error: '$cmd' is required." >&2; exit 1; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo
echo "  i  -  small shell scripts by psvim"
echo "  psv.im/i"
echo
echo "Fetching scripts from github.com/${REPO} ..."
if ! curl -fsSL "$TARBALL" | tar -xz -C "$TMP" --strip-components=1; then
  echo "Error: could not download the repo (check name/branch/internet)." >&2
  exit 1
fi

# Collect all .sh files except init.sh
SCRIPTS=()
while IFS= read -r f; do
  SCRIPTS+=("$f")
done < <(cd "$TMP" && find . -type f -name '*.sh' ! -name 'init.sh' | sed 's|^\./||' | sort)

TOTAL="${#SCRIPTS[@]}"
if [ "$TOTAL" -eq 0 ]; then
  echo "No scripts found in the repo."
  exit 0
fi

# The category is the script's folder path, e.g. "general" or "cybersecurity/exploit".
# A script sitting at the repo root (no folder) falls back to "general".
get_category() {
  local dir
  dir="$(dirname "$1")"
  if [ "$dir" = "." ]; then
    echo "general"
  else
    echo "$dir"
  fi
}

# Read "Name - description" from the line right after the shebang
get_info() {
  local info
  info="$(sed -n '2p' "$TMP/$1" | tr -d '\r' | sed -E 's/^#+[[:space:]]*//')"
  [ -n "$info" ] && echo "$info" || echo "$(basename "$1" .sh) - (no description)"
}

# Build the sorted, unique list of categories, with a count for each
CATEGORIES=()
CAT_COUNTS=()
for s in "${SCRIPTS[@]}"; do
  c="$(get_category "$s")"
  found=0
  for idx in "${!CATEGORIES[@]}"; do
    if [ "${CATEGORIES[$idx]}" = "$c" ]; then
      CAT_COUNTS[$idx]=$((CAT_COUNTS[idx] + 1))
      found=1
      break
    fi
  done
  if [ "$found" -eq 0 ]; then
    CATEGORIES+=("$c")
    CAT_COUNTS+=(1)
  fi
done
# sort categories alphabetically, carrying counts along
IFS=$'\n' SORTED_CATS=($(for i in "${!CATEGORIES[@]}"; do printf '%s\t%s\n' "${CATEGORIES[$i]}" "${CAT_COUNTS[$i]}"; done | sort)); unset IFS
CATEGORIES=(); CAT_COUNTS=()
for line in "${SORTED_CATS[@]}"; do
  CATEGORIES+=("${line%%$'\t'*}")
  CAT_COUNTS+=("${line##*$'\t'}")
done
CAT_TOTAL="${#CATEGORIES[@]}"

show_categories() {
  echo
  echo "================ Categories ================"
  local i
  for i in "${!CATEGORIES[@]}"; do
    printf "%3d) %-28s (%s)\n" "$((i + 1))" "${CATEGORIES[$i]}" "${CAT_COUNTS[$i]}"
  done
  echo "----------------------------------------------------------"
  printf "%3s) %s\n" "a" "All scripts ($TOTAL total)"
  echo "  q) Quit"
}

# Scripts belonging to a given category, in order
category_scripts() {
  local cat="$1" s
  for s in "${SCRIPTS[@]}"; do
    [ "$(get_category "$s")" = "$cat" ] && echo "$s"
  done
}

# CUR_LIST / CUR_TITLE are set by the caller before browse_list runs, since
# this script may run on bash 3.2 (default on macOS), which has no `local -n`.
CUR_LIST=()
CUR_TITLE=""

show_script_menu() {
  local page="$1" total="${#CUR_LIST[@]}"
  local pages=$(( (total + PAGE_SIZE - 1) / PAGE_SIZE ))
  local start=$((page * PAGE_SIZE)) end i
  end=$((start + PAGE_SIZE))
  [ "$end" -gt "$total" ] && end=$total

  echo
  if [ "$pages" -gt 1 ]; then
    echo "================ ${CUR_TITLE}  (page $((page + 1))/$pages, $total total) ================"
  else
    echo "================ ${CUR_TITLE}  ($total total) ================"
  fi

  i=$start
  while [ "$i" -lt "$end" ]; do
    printf "%3d) %s  [%s]\n" "$((i + 1))" "$(get_info "${CUR_LIST[$i]}")" "${CUR_LIST[$i]}"
    i=$((i + 1))
  done

  echo "----------------------------------------------------------"
  [ "$((page + 1))" -lt "$pages" ] && echo "  n) Next page"
  [ "$page" -gt 0 ] && echo "  p) Previous page"
  echo "  b) Back to categories"
  echo "  q) Quit"
}

run_script() {
  local path="$1"
  echo
  echo ">>> Running: $path"
  echo "-----------------------------------------"
  bash "$TMP/$path" </dev/tty
  local rc=$?
  echo "-----------------------------------------"
  echo ">>> Finished (exit code: $rc)"
}

# Browse CUR_LIST (set by the caller) under the heading CUR_TITLE
browse_list() {
  local page=0 total="${#CUR_LIST[@]}"
  local pages=$(( (total + PAGE_SIZE - 1) / PAGE_SIZE ))

  while true; do
    show_script_menu "$page"
    read -r -p "Select a number: " choice </dev/tty || exit 0

    case "$choice" in
      q|Q) echo "Bye! - psvim"; exit 0 ;;
      b|B) return 0 ;;
      n|N)
        if [ "$((page + 1))" -lt "$pages" ]; then page=$((page + 1)); else echo "Already on the last page."; fi
        continue ;;
      p|P)
        if [ "$page" -gt 0 ]; then page=$((page - 1)); else echo "Already on the first page."; fi
        continue ;;
      ''|*[!0-9]*) echo "Enter a number, or n / p / b / q."; continue ;;
    esac

    if [ "$choice" -lt 1 ] || [ "$choice" -gt "$total" ]; then
      echo "Number out of range (1-$total)."
      continue
    fi

    run_script "${CUR_LIST[$((choice - 1))]}"
  done
}

while true; do
  show_categories
  read -r -p "Select a category: " pick </dev/tty || exit 0

  case "$pick" in
    q|Q) echo "Bye! - psvim"; exit 0 ;;
    a|A)
      CUR_LIST=("${SCRIPTS[@]}")
      CUR_TITLE="All scripts"
      browse_list
      continue ;;
    ''|*[!0-9]*) echo "Enter a category number, or a / q."; continue ;;
  esac

  if [ "$pick" -lt 1 ] || [ "$pick" -gt "$CAT_TOTAL" ]; then
    echo "Number out of range (1-$CAT_TOTAL)."
    continue
  fi

  cat="${CATEGORIES[$((pick - 1))]}"
  CUR_LIST=()
  while IFS= read -r f; do CUR_LIST+=("$f"); done < <(category_scripts "$cat")
  CUR_TITLE="$cat"
  browse_list
done
