# ── selection ──────────────────────────────────────────────────────────────────────
# Which files apply is a per-environment decision, and it has been wrong twice.
#
# EXCLUDE_RE (deprecated, still honoured) is ONE regex, so it can only be checked in
# aggregate: "did it exclude 0 of N files". QA's carried five alternatives, three live
# and two dead -- `employee` which never matches `300-Employee`, and a `Brand/` clause
# whose files moved to `100-Brand/` -- and the aggregate count reported healthy while
# QA silently selected the whole Employee pipeline it meant to skip.
#
# EXCLUDE_PATHS is a LIST, one entry per line (or comma-separated). Each entry must
# match at least one discovered file, so a renamed directory fails loudly instead of
# becoming a no-op. That is the property a regex cannot have.
#
# An entry matches if it appears as a path SEGMENT, case-sensitively:
#   Template          -> pipelines/Template/400-sink.rw
#   300-Employee      -> pipelines/300-Employee/100-Sources.rw
#   100-Brand/400-sink.rw  -> that exact file
EXCLUDE_PATHS="${EXCLUDE_PATHS:-}"
EXCLUDE_RE="${EXCLUDE_RE:-}"
# Default OFF so this lands without changing any environment's outcome. Dev turns it
# on first; QA and prod follow once their lists are proven.
EXCLUDE_STRICT="${EXCLUDE_STRICT:-false}"

if [ -n "$EXCLUDE_PATHS" ] && [ -n "$EXCLUDE_RE" ]; then
  echo "ERROR: EXCLUDE_PATHS and EXCLUDE_RE are both set. Pick one."
  echo "       EXCLUDE_PATHS=${EXCLUDE_PATHS}"
  echo "       EXCLUDE_RE=${EXCLUDE_RE}"
  exit 1
fi

discovered_count=${#files[@]}
selected=(); excluded_count=0
declare -a dead_entries=()

if [ -n "$EXCLUDE_PATHS" ]; then
  # Normalise: commas or newlines both separate, blanks and # comments dropped.
  mapfile -t entries < <(printf '%s' "$EXCLUDE_PATHS" | tr ',' '\n' \
                          | sed 's/[[:space:]]*#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//' \
                          | sed '/^$/d')
  [ "${#entries[@]}" -gt 0 ] || { echo "ERROR: EXCLUDE_PATHS set but parsed to 0 entries"; exit 1; }

  # Per-entry hit counts -- this is the whole point.
  declare -a hits=()
  for _ in "${entries[@]}"; do hits+=(0); done

  for f in "${files[@]}"; do
    rel="${f#/pipeline/}"
    drop=0
    for i in "${!entries[@]}"; do
      e="${entries[$i]}"
      # Segment match: the entry is bounded by / or by the ends of the path.
      if [[ "/$rel/" == *"/$e/"* ]]; then
        hits[$i]=$(( hits[i] + 1 ))
        drop=1
      fi
    done
    if [ "$drop" -eq 1 ]; then
      excluded_count=$(( excluded_count + 1 ))
      echo "  exclude  ${rel}"
    else
      selected+=("$f")
    fi
  done

  echo
  echo "exclusion entries (each must match at least one file):"
  for i in "${!entries[@]}"; do
    printf '  %-40s %s file(s)\n' "${entries[$i]}" "${hits[$i]}"
    [ "${hits[$i]}" -eq 0 ] && dead_entries+=("${entries[$i]}")
  done

  if [ "${#dead_entries[@]}" -gt 0 ]; then
    echo
    echo "WARNING: ${#dead_entries[@]} exclusion entr(ies) matched NOTHING:"
    printf '         %s\n' "${dead_entries[@]}"
    echo "         A renamed directory leaves an entry like this behind, and the"
    echo "         files it meant to skip are applied instead. Check the names"
    echo "         against the pipeline tree before trusting this run."
    if [ "$EXCLUDE_STRICT" = "true" ]; then
      echo "ERROR: EXCLUDE_STRICT=true, refusing to continue on a dead entry."
      exit 1
    fi
  fi

elif [ -n "$EXCLUDE_RE" ]; then
  echo "WARNING: EXCLUDE_RE is deprecated -- it can only be validated in aggregate,"
  echo "         so a half-dead pattern reports healthy. Move to EXCLUDE_PATHS."
  for f in "${files[@]}"; do
    rel="${f#/pipeline/}"
    if printf '%s\n' "$rel" | grep -qE "$EXCLUDE_RE"; then
      excluded_count=$(( excluded_count + 1 ))
      echo "  exclude  ${rel}"
    else
      selected+=("$f")
    fi
  done
  if [ "$excluded_count" -eq 0 ]; then
    echo "WARNING: EXCLUDE_RE is set and excluded 0 of ${discovered_count} files."
    echo "         EXCLUDE_RE=${EXCLUDE_RE}"
    if [ "$EXCLUDE_STRICT" = "true" ]; then
      echo "ERROR: EXCLUDE_STRICT=true, refusing to continue on a dead pattern."
      exit 1
    fi
  fi
else
  selected=("${files[@]}")
fi

if [ "$discovered_count" -eq 0 ]; then
  echo "ERROR: no .sql or .rw files under ${PIPELINE_DIR}"
  exit 1
fi
if [ "${#selected[@]}" -eq 0 ]; then
  echo "ERROR: every one of ${discovered_count} pipeline files was excluded."
  echo "       Check the exclusion list before applying this environment."
  exit 1
fi

files=("${selected[@]}")
echo
echo "selection    : ${#files[@]} of ${discovered_count} files will be considered"
