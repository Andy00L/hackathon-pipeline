#!/usr/bin/env bash
# ============================================================================
# lib/utils.sh — Fonctions utilitaires du pipeline hackathon
# ============================================================================

# ── Logging ─────────────────────────────────────────────────────────────────
log() {
  local level="$1"
  shift
  local msg="$*"
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[${timestamp}] [${level}] ${msg}"

  # Append to project log file if PROJECT_DIR is set
  if [[ -n "${PROJECT_DIR:-}" && -d "${PROJECT_DIR}" ]]; then
    echo "[${timestamp}] [${level}] ${msg}" >> "${PROJECT_DIR}/.pipeline.log" 2>/dev/null || true
  fi

  # Append to structured events log if available
  if [[ -n "${EVENTS_LOG:-}" ]]; then
    echo "${timestamp} | ${level} | ${msg}" >> "$EVENTS_LOG" 2>/dev/null || true
  fi
}

# ── Load config ─────────────────────────────────────────────────────────────
# Sources hackathon.conf after validating its syntax.
load_config() {
  local conf_file="$1"

  if [[ ! -f "$conf_file" ]]; then
    echo "ERREUR : fichier de configuration introuvable : ${conf_file}"
    exit 1
  fi

  # Validate bash syntax before sourcing
  if ! bash -n "$conf_file" 2>/dev/null; then
    echo "ERREUR : erreur de syntaxe dans ${conf_file}"
    exit 1
  fi

  source "$conf_file"
}

# ── Check prerequisites ────────────────────────────────────────────────────
# Verifies that required config values are set and safe.
check_prereqs() {
  local errors=0

  if [[ -z "${HACKATHON_NAME:-}" ]]; then
    echo "ERREUR : HACKATHON_NAME est vide dans hackathon.conf"
    errors=$((errors + 1))
  fi

  if [[ -z "${PROJECT_DIR:-}" ]]; then
    echo "ERREUR : PROJECT_DIR est vide dans hackathon.conf"
    errors=$((errors + 1))
  fi

  # Validate that shell-sensitive config values don't contain metacharacters
  local safe_pattern='^[a-zA-Z0-9._-]+$'
  if [[ -n "${CLAUDE_MODEL:-}" && ! "${CLAUDE_MODEL}" =~ $safe_pattern ]]; then
    echo "ERREUR : CLAUDE_MODEL contient des caractères interdits (attendu : lettres, chiffres, ._-)"
    errors=$((errors + 1))
  fi
  if [[ -n "${CLAUDE_EFFORT:-}" && ! "${CLAUDE_EFFORT}" =~ $safe_pattern ]]; then
    echo "ERREUR : CLAUDE_EFFORT contient des caractères interdits (attendu : lettres, chiffres, ._-)"
    errors=$((errors + 1))
  fi

  # Verify essential tools
  for cmd in git jq tmux; do
    if ! command -v "$cmd" &>/dev/null; then
      echo "ERREUR : commande requise manquante : ${cmd}"
      errors=$((errors + 1))
    fi
  done

  if ! command -v claude &>/dev/null; then
    echo "ERREUR : Claude Code CLI non trouvé. Installe-le d'abord."
    errors=$((errors + 1))
  fi

  if (( errors > 0 )); then
    echo ""
    echo "${errors} erreur(s) détectée(s). Corrige et relance."
    exit 1
  fi
}

# ── Git init ────────────────────────────────────────────────────────────────
# Initializes a git repo in PROJECT_DIR if one doesn't exist.
git_init() {
  mkdir -p "$PROJECT_DIR"

  if [[ ! -d "${PROJECT_DIR}/.git" ]]; then
    git -C "$PROJECT_DIR" init
    log "INFO" "Repo git initialisé dans ${PROJECT_DIR}"

    # Create a .gitignore if none exists
    if [[ ! -f "${PROJECT_DIR}/.gitignore" ]]; then
      cat > "${PROJECT_DIR}/.gitignore" << 'GITIGNORE'
node_modules/
.env
.env.local
.env.*.local
venv/
__pycache__/
dist/
build/
.next/
target/
*.log
.pipeline/
.pipeline.log
.pipeline-live.log
.pipeline.lock
.ultraplan-done
.DS_Store
.claude-stderr.log
GITIGNORE
      log "INFO" ".gitignore créé"
    fi
  else
    log "INFO" "Repo git existant dans ${PROJECT_DIR}"
  fi
}

# ── Ensure GitHub ──────────────────────────────────────────────────────────
# Creates or connects a GitHub repo for the project.
ensure_github() {
  cd "$PROJECT_DIR"

  if [[ -n "${GITHUB_REPO:-}" ]]; then
    # User specified an existing repo
    if ! git remote get-url origin &>/dev/null; then
      git remote add origin "https://github.com/${GITHUB_REPO}.git"
      log "INFO" "Remote ajouté : ${GITHUB_REPO}"
    fi
  else
    # Create a new repo if no remote exists
    if ! git remote get-url origin &>/dev/null; then
      local slug
      slug=$(echo "$HACKATHON_NAME" | sed -E 's/[^a-zA-Z0-9]+/-/g; s/^-+|-+$//g' | tr '[:upper:]' '[:lower:]')
      slug="${slug:-hackathon-project}"
      local visibility="${GITHUB_VISIBILITY:-public}"

      # Need at least one commit before gh repo create --source=.
      if ! git -C "$PROJECT_DIR" log --oneline -1 &>/dev/null; then
        git -C "$PROJECT_DIR" commit --allow-empty -m "initial commit"
      fi

      gh repo create "$slug" --"$visibility" --source=. --push 2>/dev/null || {
        local gh_user
        gh_user=$(gh api user -q '.login' 2>/dev/null) || true
        if [[ -n "$gh_user" ]]; then
          git remote add origin "https://github.com/${gh_user}/${slug}.git" 2>/dev/null || true
          GITHUB_REPO="${gh_user}/${slug}"
        fi
      }
      log "INFO" "Repo GitHub configuré"
    else
      log "INFO" "Remote GitHub existant"
    fi
  fi
}

# ── Inject CLAUDE.md ───────────────────────────────────────────────────────
# Generates CLAUDE.md in the project from the pipeline template.
inject_claude_md() {
  local pipeline_dir="$1"
  local template="${pipeline_dir}/templates/CLAUDE.md.template"
  local output="${PROJECT_DIR}/CLAUDE.md"

  if [[ ! -f "$template" ]]; then
    log "WARN" "Template CLAUDE.md introuvable : ${template}"
    return 1
  fi

  # Read input files from the pipeline's inputs/ directory
  local brief="" criteria="" resources=""

  if [[ -f "${pipeline_dir}/inputs/brief.md" ]]; then
    brief=$(cat "${pipeline_dir}/inputs/brief.md")
  fi
  if [[ -f "${pipeline_dir}/inputs/criteria.md" ]]; then
    criteria=$(cat "${pipeline_dir}/inputs/criteria.md")
  fi
  if [[ -f "${pipeline_dir}/inputs/resources.md" ]]; then
    resources=$(cat "${pipeline_dir}/inputs/resources.md")
  fi

  brief="${brief:-Aucun brief fourni. Lis les fichiers dans inputs/.}"
  criteria="${criteria:-Non spécifiés.}"
  resources="${resources:-Aucune ressource fournie.}"

  # Read template and perform substitutions via bash parameter expansion
  local content
  content=$(cat "$template")
  content="${content//\{\{HACKATHON_NAME\}\}/${HACKATHON_NAME}}"
  content="${content//\{\{HACKATHON_DEADLINE\}\}/${HACKATHON_DEADLINE:-non spécifiée}}"
  content="${content//\{\{HACKATHON_THEME\}\}/${HACKATHON_THEME:-libre}}"
  content="${content//\{\{HACKATHON_BRIEF\}\}/${brief}}"
  content="${content//\{\{HACKATHON_CRITERIA\}\}/${criteria}}"
  content="${content//\{\{HACKATHON_RESOURCES\}\}/${resources}}"

  printf '%s\n' "$content" > "$output"

  # Copy REFERENCE files to project docs/
  mkdir -p "${PROJECT_DIR}/docs"
  cp "${pipeline_dir}/REFERENCE_SECURITY_AUDIT.md" "${PROJECT_DIR}/docs/" 2>/dev/null || true
  cp "${pipeline_dir}/REFERENCE_DOCUMENTATION_AUDIT.md" "${PROJECT_DIR}/docs/" 2>/dev/null || true

  log "INFO" "CLAUDE.md généré dans ${PROJECT_DIR}"
}

# ── Git checkpoint ─────────────────────────────────────────────────────────
# Stages all changes and commits with the given message.
git_checkpoint() {
  local message="$1"
  cd "$PROJECT_DIR"
  git add -A

  # Only commit if there are staged changes
  if ! git diff --cached --quiet 2>/dev/null; then
    git commit -m "$message"
    log "INFO" "Commit : ${message}"
  else
    log "INFO" "Rien à commiter"
  fi
}
