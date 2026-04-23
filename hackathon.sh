#!/usr/bin/env bash
set -euo pipefail
# ============================================================================
# hackathon.sh — Point d'entrée du pipeline hackathon autonome
#
# Usage :
#   ./hackathon.sh                  Lance le pipeline complet
#   ./hackathon.sh --skip-ultraplan Skip ultraplan, direct Agent Teams
#   ./hackathon.sh --attach         Attach à la session tmux (no setup)
#   ./hackathon.sh --watch          Show filtered live logs (no setup)
#
# Au premier lancement, auto_setup() installe automatiquement tous les
# prérequis : outils système, GitHub CLI, plugins Claude Code, NOPASSWD sudo.
# Ensuite, il ne reste qu'à remplir hackathon.conf et déposer les inputs.
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMUX_SESSION="hackathon"

# ── Vérifier que les fichiers lib/ existent avant toute modification système ──
for _required_file in "${SCRIPT_DIR}/lib/utils.sh" "${SCRIPT_DIR}/lib/telegram.sh"; do
  if [[ ! -f "$_required_file" ]]; then
    echo "ERREUR : fichier requis manquant : ${_required_file}"
    echo "Le pipeline ne peut pas démarrer sans les fichiers lib/."
    exit 1
  fi
done
unset _required_file

# ── Parse des arguments (AVANT tout setup) ──────────────────────────────────
SKIP_ULTRAPLAN=false
WATCH_MODE=false
ATTACH_MODE=false
DRY_RUN="${DRY_RUN:-0}"

for arg in "$@"; do
  case "$arg" in
    --skip-ultraplan) SKIP_ULTRAPLAN=true ;;
    --watch)          WATCH_MODE=true ;;
    --attach)         ATTACH_MODE=true ;;
    --help|-h)
      echo "Usage: ./hackathon.sh [options]"
      echo ""
      echo "Options:"
      echo "  --skip-ultraplan  Skip ultraplan, agents create their own plan"
      echo "  --watch           Show filtered live logs (no setup)"
      echo "  --attach          Attach to tmux session (no setup)"
      echo "  --help            Show this help"
      exit 0
      ;;
    *)
      echo "Option inconnue: $arg"
      echo "Usage: ./hackathon.sh [--skip-ultraplan] [--watch] [--attach] [--help]"
      exit 1
      ;;
  esac
done

# ── Mode watch : juste les logs, pas de setup ───────────────────────────────
if [[ "$WATCH_MODE" == "true" ]]; then
  if [[ -f "${SCRIPT_DIR}/hackathon.conf" ]]; then
    source "${SCRIPT_DIR}/hackathon.conf"
  fi
  LIVE_LOG="${PROJECT_DIR:-.}/.pipeline-live.log"
  if [[ ! -f "$LIVE_LOG" ]]; then
    echo "Pas de session active. Lance d'abord ./hackathon.sh"
    exit 1
  fi
  echo "Watch mode : $LIVE_LOG"
  echo "Ctrl+C pour quitter (la session continue)"
  tail -f "$LIVE_LOG" | grep --line-buffered -iE \
    "phase|commit|error|warn|score|pass|fail|ready|human|deploy|push|✓|✗" \
    || true
  exit 0
fi

# ── Mode attach : juste tmux, pas de setup ──────────────────────────────────
if [[ "$ATTACH_MODE" == "true" ]]; then
  if tmux has-session -t hackathon 2>/dev/null; then
    tmux attach -t hackathon
  else
    echo "Pas de session tmux 'hackathon' active."
    echo "Lance d'abord ./hackathon.sh"
  fi
  exit 0
fi

# ── Auto-setup : installation automatique des prérequis ─────────────────────
# Idempotent : vérifie ce qui est déjà installé et n'installe que le manquant.
# Les commandes sudo promptent le mot de passe dans le terminal tant que
# NOPASSWD n'est pas configuré — c'est le comportement voulu.
# ────────────────────────────────────────────────────────────────────────────
auto_setup() {
  echo ""
  echo "════════════════════════════════════════"
  echo "  Auto-setup pipeline hackathon"
  echo "════════════════════════════════════════"
  echo ""

  # ── 1. Outils système ──────────────────────────────────────────────────
  local missing_pkgs=()

  echo "[1/6] Outils système..."

  for cmd_pkg in git:git curl:curl jq:jq tmux:tmux zip:zip; do
    local cmd="${cmd_pkg%%:*}"
    local pkg="${cmd_pkg##*:}"
    if ! command -v "$cmd" &>/dev/null; then
      missing_pkgs+=("$pkg")
    else
      echo "  ✓ ${cmd}"
    fi
  done

  if ! dpkg -l build-essential 2>/dev/null | grep -q "^ii"; then
    missing_pkgs+=("build-essential")
  else
    echo "  ✓ build-essential"
  fi

  if (( ${#missing_pkgs[@]} > 0 )); then
    echo "  → Installation de : ${missing_pkgs[*]}"
    sudo apt-get update -qq
    sudo apt-get install -y "${missing_pkgs[@]}"
    echo "  ✓ Paquets installés"
  fi

  echo ""

  # ── 2. GitHub CLI ──────────────────────────────────────────────────────
  echo "[2/6] GitHub CLI..."

  if ! command -v gh &>/dev/null; then
    echo "  → Installation de GitHub CLI..."
    (type -p wget >/dev/null || sudo apt-get install -y wget) && \
    sudo mkdir -p -m 755 /etc/apt/keyrings && \
    wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null && \
    sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null && \
    sudo apt-get update -qq && \
    sudo apt-get install -y gh
    echo "  ✓ GitHub CLI installé"
  else
    echo "  ✓ gh $(gh version 2>/dev/null | head -1 | awk '{print $3}')"
  fi

  echo ""

  # ── 3. Authentification GitHub ─────────────────────────────────────────
  echo "[3/6] Authentification GitHub..."

  if ! gh auth status &>/dev/null 2>&1; then
    echo "  ⚠ GitHub CLI non authentifié."
    echo "  → Lancement de gh auth login..."
    echo ""
    gh auth login
    echo ""
    echo "  ✓ GitHub CLI authentifié"
  else
    echo "  ✓ gh authentifié"
  fi

  echo ""

  # ── 4. Claude Code ────────────────────────────────────────────────────
  echo "[4/6] Claude Code..."

  if ! claude auth status --text &>/dev/null 2>&1; then
    echo ""
    echo "  ✗ Claude Code n'est pas authentifié."
    echo "    Lance : claude auth login"
    echo ""
    exit 1
  else
    echo "  ✓ Claude Code authentifié"
  fi

  echo ""

  # ── 5. NOPASSWD sudo ─────────────────────────────────────────────────
  echo "[5/6] NOPASSWD sudo..."

  if ! sudo -n true 2>/dev/null; then
    echo "  → Configuration de NOPASSWD sudo (apt-get seulement)..."
    echo "    (dernière fois qu'un mot de passe sudo sera demandé)"
    local sudoers_file
    sudoers_file="/etc/sudoers.d/hackathon-$(whoami)"
    echo "$(whoami) ALL=(ALL) NOPASSWD: /usr/bin/apt-get, /bin/mkdir, /usr/bin/tee, /bin/chmod" \
      | sudo tee "$sudoers_file" > /dev/null
    sudo chmod 0440 "$sudoers_file"
    echo "  ✓ NOPASSWD sudo configuré (apt-get, mkdir, tee, chmod)"
  else
    echo "  ✓ NOPASSWD sudo déjà configuré"
  fi

  echo ""

  # ── 6. Plugins Claude Code ───────────────────────────────────────────
  echo "[6/6] Plugins Claude Code..."

  local plugins=(
    "frontend-design@claude-plugins-official"
    "security-guidance@claude-plugins-official"
    "code-review@claude-plugins-official"
    "feature-dev@claude-plugins-official"
  )

  for plugin in "${plugins[@]}"; do
    echo "  → ${plugin}..."
    claude plugin install "$plugin" 2>/dev/null \
      && echo "  ✓ ${plugin}" \
      || echo "  ~ ${plugin} (déjà installé ou indisponible)"
  done

  # UI/UX Pro Max (marketplace communautaire)
  echo "  → marketplace nextlevelbuilder/ui-ux-pro-max-skill..."
  claude plugin marketplace add nextlevelbuilder/ui-ux-pro-max-skill 2>/dev/null || true
  echo "  → ui-ux-pro-max..."
  claude plugin install ui-ux-pro-max@ui-ux-pro-max-skill 2>/dev/null && \
    echo "  ✓ ui-ux-pro-max" || echo "  ~ ui-ux-pro-max (déjà installé ou erreur)"

  echo ""
  echo "  Plugins installés :"
  if command -v claude &>/dev/null; then
    claude plugin list 2>/dev/null | head -20 || echo "  (impossible de lister les plugins)"
  fi

  echo ""
  echo "════════════════════════════════════════"
  echo "  Auto-setup terminé"
  echo "════════════════════════════════════════"
  echo ""
}

# ── Escape helper pour hackathon.conf ────────────────────────────────────────
_escape_conf_value() {
  local val="$1"
  val="${val//\\/\\\\}"
  val="${val//\$/\\\$}"
  val="${val//\`/\\\`}"
  val="${val//\"/\\\"}"
  printf '%s' "$val"
}

# ── Configuration interactive ────────────────────────────────────────────────
# Crée ou met à jour hackathon.conf via un formulaire interactif.
# Appelé après auto_setup() et avant load_config().
# ────────────────────────────────────────────────────────────────────────────
interactive_config() {
  local conf_file="${SCRIPT_DIR}/hackathon.conf"

  # Si le fichier existe et HACKATHON_NAME est rempli, proposer de le garder
  if [[ -f "$conf_file" ]]; then
    local existing_name
    existing_name=$(grep '^HACKATHON_NAME=' "$conf_file" | head -1 | sed 's/^[^"]*"//; s/".*//')
    if [[ -n "$existing_name" ]]; then
      echo "Config existante : ${existing_name}"
      local use_existing
      read -rp "Utiliser cette config ? (o/n) [o] : " use_existing
      use_existing="${use_existing:-o}"
      if [[ "$use_existing" =~ ^[oOyY]$ ]]; then
        return 0
      fi
    fi
  fi

  echo ""
  echo "════════════════════════════════════════"
  echo "  Configuration du hackathon"
  echo "════════════════════════════════════════"
  echo ""

  local current_value input

  # 1. HACKATHON_NAME — obligatoire
  current_value=""
  [[ -f "$conf_file" ]] && current_value=$(grep '^HACKATHON_NAME=' "$conf_file" | head -1 | sed 's/^[^"]*"//; s/".*//')
  local HACKATHON_NAME=""
  while true; do
    if [[ -n "$current_value" ]]; then
      read -rp "Nom du hackathon [${current_value}] : " input
    else
      read -rp "Nom du hackathon : " input
    fi
    HACKATHON_NAME="${input:-${current_value}}"
    if [[ -n "$HACKATHON_NAME" ]]; then
      break
    fi
    echo "Le nom est obligatoire."
  done

  # Calculer le slug pour le défaut PROJECT_DIR
  local name_slug
  name_slug=$(echo "$HACKATHON_NAME" | sed -E 's/[^a-zA-Z0-9]+/-/g' | sed -E 's/^-+|-+$//g' | tr '[:upper:]' '[:lower:]')
  name_slug="${name_slug:-hackathon-project}"
  local default_project="$HOME/hackathons/${name_slug}"

  # 2. HACKATHON_DEADLINE — optionnel
  current_value=""
  [[ -f "$conf_file" ]] && current_value=$(grep '^HACKATHON_DEADLINE=' "$conf_file" | head -1 | sed 's/^[^"]*"//; s/".*//')
  read -rp "Deadline (ex: 2026-04-20T23:59:00) [${current_value:-aucune}] : " input
  local HACKATHON_DEADLINE="${input:-${current_value}}"

  # 3. HACKATHON_THEME — optionnel
  current_value=""
  [[ -f "$conf_file" ]] && current_value=$(grep '^HACKATHON_THEME=' "$conf_file" | head -1 | sed 's/^[^"]*"//; s/".*//')
  if [[ -n "$current_value" ]]; then
    read -rp "Thème (vide si libre) [${current_value}] : " input
  else
    read -rp "Thème (vide si libre) : " input
  fi
  local HACKATHON_THEME="${input:-${current_value}}"

  # 4. PROJECT_DIR — défaut ~/hackathons/<slug>
  current_value=""
  [[ -f "$conf_file" ]] && current_value=$(grep '^PROJECT_DIR=' "$conf_file" | head -1 | sed 's/^[^"]*"//; s/".*//')
  read -rp "Dossier du projet [${current_value:-${default_project}}] : " input
  local PROJECT_DIR="${input:-${current_value:-${default_project}}}"

  # Protection : le projet ne doit PAS être dans le dossier pipeline
  while true; do
    local project_resolved
    project_resolved=$(realpath -m "$PROJECT_DIR" 2>/dev/null)
    if [[ -z "$project_resolved" ]]; then
      project_resolved=$(readlink -f "$PROJECT_DIR" 2>/dev/null || echo "$PROJECT_DIR")
    fi

    if [[ "$project_resolved" == "$SCRIPT_DIR" ]] || \
       [[ "$project_resolved" == "$SCRIPT_DIR/"* ]]; then
      echo ""
      echo "  Le projet ne peut pas être dans le dossier de la pipeline."
      echo "  Pipeline : $SCRIPT_DIR"
      echo "  Suggestion : ~/hackathons/${name_slug}"
      echo ""
      read -rp "  Dossier du projet [${default_project}] : " input
      PROJECT_DIR="${input:-${default_project}}"
    else
      break
    fi
  done

  # 5. GITHUB_REPO — optionnel
  current_value=""
  [[ -f "$conf_file" ]] && current_value=$(grep '^GITHUB_REPO=' "$conf_file" | head -1 | sed 's/^[^"]*"//; s/".*//')
  if [[ -n "$current_value" ]]; then
    read -rp "Repo GitHub existant (vide = en créer un, ex: user/repo) [${current_value}] : " input
  else
    read -rp "Repo GitHub existant (vide = en créer un, ex: user/repo) : " input
  fi
  local GITHUB_REPO="${input:-${current_value}}"

  # 6. TELEGRAM_BOT_TOKEN — optionnel
  current_value=""
  [[ -f "$conf_file" ]] && current_value=$(grep '^TELEGRAM_BOT_TOKEN=' "$conf_file" | head -1 | sed 's/^[^"]*"//; s/".*//')
  if [[ -n "$current_value" ]]; then
    read -rp "Telegram Bot Token (vide pour skip) [${current_value}] : " input
  else
    read -rp "Telegram Bot Token (vide pour skip) : " input
  fi
  local TELEGRAM_BOT_TOKEN="${input:-${current_value}}"

  # 7. TELEGRAM_CHAT_ID — conditionnel
  local TELEGRAM_CHAT_ID=""
  if [[ -n "$TELEGRAM_BOT_TOKEN" ]]; then
    if ! command -v jq &>/dev/null; then
      echo "jq non disponible — saisie manuelle du Chat ID."
      read -rp "Tape ton Chat ID : " TELEGRAM_CHAT_ID
    else
      # Vérifier si le token est valide
      local bot_check
      bot_check=$(curl -s --max-time 10 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe" 2>/dev/null) || true

      if [[ -z "$bot_check" ]]; then
        # curl a échoué (timeout réseau)
        echo "Impossible de contacter l'API Telegram. Saisie manuelle."
        read -rp "Chat ID (vide pour désactiver Telegram) : " TELEGRAM_CHAT_ID
        [[ -z "$TELEGRAM_CHAT_ID" ]] && TELEGRAM_BOT_TOKEN=""
      elif ! echo "$bot_check" | jq -e '.ok' &>/dev/null; then
        echo "Token invalide. Telegram sera désactivé."
        TELEGRAM_BOT_TOKEN=""
      else
        # Token valide — proposer la détection auto
        echo ""
        echo "Pour détecter ton Chat ID automatiquement :"
        echo "  1. Ouvre Telegram"
        echo "  2. Envoie un message à ton bot (n'importe quoi)"
        read -rp "  3. Appuie sur Entrée ici quand c'est fait..."

        local detected_id use_id retry
        local attempt
        for attempt in 1 2 3; do
          detected_id=$(curl -s --max-time 10 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates" 2>/dev/null \
            | jq -r '.result[-1].message.chat.id // empty' 2>/dev/null) || true

          if [[ -n "$detected_id" && "$detected_id" != "null" ]]; then
            echo "Chat ID détecté : ${detected_id}"
            read -rp "Utiliser ce Chat ID ? (o/n) [o] : " use_id
            use_id="${use_id:-o}"
            if [[ "$use_id" =~ ^[oOyY]$ ]]; then
              TELEGRAM_CHAT_ID="$detected_id"
            else
              read -rp "Tape ton Chat ID manuellement : " TELEGRAM_CHAT_ID
            fi
            break
          fi

          if (( attempt < 3 )); then
            echo "Aucun message trouvé. As-tu bien envoyé un message au bot ?"
            read -rp "Réessayer ? (o/n) [o] : " retry
            retry="${retry:-o}"
            if [[ ! "$retry" =~ ^[oOyY]$ ]]; then
              read -rp "Tape ton Chat ID manuellement : " TELEGRAM_CHAT_ID
              break
            fi
          else
            echo "Aucun message trouvé après 3 tentatives."
            read -rp "Tape ton Chat ID manuellement : " TELEGRAM_CHAT_ID
          fi
        done
      fi
    fi
  fi

  # Échapper les guillemets doubles pour le fichier conf
  local esc_name esc_deadline esc_theme esc_dir esc_repo esc_tg_token esc_tg_chatid
  esc_name=$(_escape_conf_value "$HACKATHON_NAME")
  esc_deadline=$(_escape_conf_value "$HACKATHON_DEADLINE")
  esc_theme=$(_escape_conf_value "$HACKATHON_THEME")
  esc_dir=$(_escape_conf_value "$PROJECT_DIR")
  esc_repo=$(_escape_conf_value "$GITHUB_REPO")
  esc_tg_token=$(_escape_conf_value "$TELEGRAM_BOT_TOKEN")
  esc_tg_chatid=$(_escape_conf_value "$TELEGRAM_CHAT_ID")

  # Générer hackathon.conf
  cat << CONF > "$conf_file"
#!/usr/bin/env bash
# ============================================================================
# hackathon.conf — Configuration du pipeline hackathon
#
# INSTRUCTIONS :
#   1. Copie hackathon.conf.example vers hackathon.conf
#   2. Remplis les champs obligatoires
#   3. Lance ./hackathon.sh
# ============================================================================

# ── Hackathon ────────────────────────────────────────────────────────────────
# Obligatoire : le nom et la deadline
HACKATHON_NAME="${esc_name}"
HACKATHON_DEADLINE="${esc_deadline}"          # Format ISO : 2026-04-20T23:59:00
HACKATHON_THEME="${esc_theme}"             # Thème imposé (vide si libre)

# ── Projet ───────────────────────────────────────────────────────────────────
# Répertoire où le code du hackathon sera généré
# Par défaut : ~/hackathons/<nom-du-hackathon>
PROJECT_DIR="${esc_dir}"

# ── GitHub ───────────────────────────────────────────────────────────────────
# Si vide, le pipeline crée un repo via gh repo create
# Si rempli, le pipeline clone ce repo
GITHUB_REPO="${esc_repo}"                 # Ex: "monuser/hackathon-2026"
GITHUB_VISIBILITY="public"    # public | private

# ── Telegram (recommandé) ───────────────────────────────────────────────────
# Créé via @BotFather sur Telegram
# Sans Telegram, le pipeline fonctionne mais ne peut pas te notifier
TELEGRAM_BOT_TOKEN="${esc_tg_token}"
TELEGRAM_CHAT_ID="${esc_tg_chatid}"

# ── Modèle ───────────────────────────────────────────────────────────────────
# Ne change pas sauf si tu sais ce que tu fais
CLAUDE_MODEL="opus"
CLAUDE_EFFORT="max"
CLAUDE_FALLBACK="sonnet"
CONF

  # Vérifier la syntaxe du fichier généré
  if ! bash -n "$conf_file"; then
    echo ""
    echo "ERREUR : hackathon.conf généré contient une erreur de syntaxe."
    echo "Vérifie et corrige manuellement : ${conf_file}"
    exit 1
  fi

  # Résumé
  local tg_status="non configuré"
  [[ -n "$TELEGRAM_BOT_TOKEN" ]] && tg_status="configuré"

  echo ""
  echo "════════════════════════════════════════"
  echo "  Configuration sauvegardée"
  echo "════════════════════════════════════════"
  echo "  Nom       : ${HACKATHON_NAME}"
  echo "  Deadline  : ${HACKATHON_DEADLINE:-non spécifiée}"
  echo "  Thème     : ${HACKATHON_THEME:-libre}"
  echo "  Projet    : ${PROJECT_DIR}"
  echo "  GitHub    : ${GITHUB_REPO:-sera créé automatiquement}"
  echo "  Telegram  : ${tg_status}"
  echo "════════════════════════════════════════"
  echo ""
}

# ── Safeguards : protection du repo GitHub et commandes dangereuses ─────────
# Crée/merge .claude/settings.json avec deny rules, allow rules,
# et un hook PreToolUse qui bloque activement les commandes dangereuses.
# ────────────────────────────────────────────────────────────────────────────
setup_safeguards() {
  local settings_file="${PROJECT_DIR}/.claude/settings.json"
  local hook_dir="${PROJECT_DIR}/.claude/hooks"
  local templates_dir="${SCRIPT_DIR}/templates/hooks"
  mkdir -p "$hook_dir"

  # Copy hook scripts from templates, chmod +x
  local hook_files=("pretooluse-safeguard.sh" "precompact-checkpoint.sh" "posttooluse-fanout.sh")
  for hf in "${hook_files[@]}"; do
    if [[ -f "${templates_dir}/${hf}" ]]; then
      cp "${templates_dir}/${hf}" "${hook_dir}/${hf}"
      chmod +x "${hook_dir}/${hf}"
    else
      log "WARN" "Template hook not found: ${templates_dir}/${hf}"
    fi
  done

  local pretooluse_hook="${hook_dir}/pretooluse-safeguard.sh"
  local precompact_hook="${hook_dir}/precompact-checkpoint.sh"
  local posttooluse_hook="${hook_dir}/posttooluse-fanout.sh"

  # Baseline permissions.allow — rationale for the non-obvious entries:
  #   - "mcp__pipeline-coordinator__*" : 8 coordinator tools (post_message,
  #     claim_next, record_verdict, request_gate, get_latest_diff,
  #     acquire_file_lock, release_file_lock, heartbeat). Server-side,
  #     none touch git / shell / FS outside .pipeline/. Without this
  #     wildcard, a fresh settings.json denies every orchestrator MCP call
  #     (observed in a live run — patched by hand with jq).
  #   - "Agent" + "Agent(*)" + explicit Agent(name) entries : orchestrators
  #     spawn sub-agents; the wildcard covers any future sub-agent name
  #     without enumeration. The enumerated entries remain for
  #     /permissions visibility. Sub-agents are defined in this repo —
  #     the model can't inject new names.
  # The jq merge below uses `unique`, so re-running setup_safeguards on a
  # pre-existing settings.json is a dedup no-op.
  local safeguards
  safeguards=$(cat <<SAFEGUARDS_EOF
{
  "permissions": {
    "defaultMode": "acceptEdits",
    "deny": [
      "Bash(gh repo delete *)",
      "Bash(gh repo archive *)",
      "Bash(gh repo edit *)",
      "Bash(git push --force *)",
      "Bash(git push * --force)",
      "Bash(git push --force-with-lease *)",
      "Bash(rm -rf /)",
      "Bash(rm -rf ~)",
      "Bash(rm -rf /*)",
      "Bash(rm -rf .)",
      "Bash(rm -r -f *)",
      "Bash(git push origin --force *)",
      "Bash(git reset --hard *)",
      "Bash(chmod 777 *)",
      "Bash(chmod -R 777 *)",
      "Bash(mkfs.*)",
      "Bash(dd if=*)"
    ],
    "allow": [
      "Bash",
      "Read",
      "Write",
      "Edit",
      "MultiEdit",
      "Glob",
      "Grep",
      "WebFetch",
      "WebSearch",
      "Agent",
      "Agent(*)",
      "Agent(architecte)",
      "Agent(implementeur)",
      "Agent(securite)",
      "Agent(qualite)",
      "Agent(uiux-designer)",
      "Agent(docs-reader)",
      "Agent(package-research)",
      "Agent(readme-specialist)",
      "Agent(injection-specialist)",
      "Agent(secrets-config-specialist)",
      "Agent(auth-crypto-specialist)",
      "Agent(deps-auditor)",
      "Agent(threat-modeler)",
      "Agent(ui-quality-reviewer)",
      "Agent(code-quality-reviewer)",
      "Agent(docs-auditor)",
      "Agent(scratch-tester)",
      "mcp__pipeline-coordinator__*"
    ]
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "${pretooluse_hook}"
          }
        ]
      }
    ],
    "PreCompact": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${precompact_hook}"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Edit|Write|MultiEdit",
        "hooks": [
          {
            "type": "command",
            "command": "${posttooluse_hook}"
          }
        ]
      }
    ]
  }
}
SAFEGUARDS_EOF
)

  if [[ -f "$settings_file" ]]; then
    local merged
    merged=$(jq --argjson sg "$safeguards" '
      .permissions.defaultMode = $sg.permissions.defaultMode |
      .permissions.deny = ((.permissions.deny // []) + $sg.permissions.deny | unique) |
      .permissions.allow = ((.permissions.allow // []) + $sg.permissions.allow | unique) |
      .hooks.PreToolUse = (
        [(.hooks.PreToolUse // [])[], ($sg.hooks.PreToolUse // [])[]]
        | unique_by(.matcher // "")
      ) |
      .hooks.PreCompact = (
        [(.hooks.PreCompact // [])[], ($sg.hooks.PreCompact // [])[]]
        | unique_by(.hooks[0].command // "")
      ) |
      .hooks.PostToolUse = (
        [(.hooks.PostToolUse // [])[], ($sg.hooks.PostToolUse // [])[]]
        | unique_by(.matcher // "")
      ) |
      del(.env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS)
    ' "$settings_file")
    echo "$merged" > "$settings_file"
  else
    echo "$safeguards" > "$settings_file"
  fi

  log "INFO" "Safeguards configures (3 hooks: PreToolUse, PreCompact, PostToolUse)"
}

# ── Lancer Claude dans tmux (sans race condition) ───────────────────────────
# Crée un script temporaire pour lancer Claude comme processus initial de tmux
# au lieu de new-session + send-keys. Résout les race conditions documentées
# dans les GitHub issues #40168, #33987, #37217.
# Usage : launch_claude_in_tmux "prompt" "session_name" "project_dir" "claude_cmd"
# Retourne 0 si Claude démarre, 1 sinon.
# ────────────────────────────────────────────────────────────────────────────
launch_claude_in_tmux() {
  local prompt="$1"
  local session_name="$2"
  local project_dir="$3"
  local claude_cmd="$4"

  # Écrire le script de lancement avec prompt en heredoc
  # Le heredoc 'PROMPT_EOF' (single-quoted) empêche toute expansion bash
  # dans le contenu du prompt — parenthèses, $, etc. sont inertes
  local cmd_file
  cmd_file=$(mktemp /tmp/hackathon-cmd-XXXXXX.sh)
  chmod +x "$cmd_file"
  {
    cat <<CMDEOF
#!/bin/bash
rm -f "\$0"
cd "${project_dir}"
exec ${claude_cmd} <<'PROMPT_EOF'
CMDEOF
    printf '%s\n' "$prompt"
    echo "PROMPT_EOF"
  } > "$cmd_file"

  # Lancer le script comme processus initial du tmux (pas de race condition)
  tmux new-session -d -s "$session_name" "$cmd_file"

  # Vérifier que Claude a bien démarré (pas un prompt bash)
  sleep 10
  local verify_content
  verify_content=$(tmux capture-pane -t "$session_name" -p 2>/dev/null || echo "")
  if echo "$verify_content" | grep -qE '(drew@|bash-[0-9]|\$\s*$)'; then
    log "ERROR" "Claude Code n'a pas démarré. Prompt bash détecté."
    return 1
  fi
  log "INFO" "Claude Code vérifié : en cours d'exécution"
  return 0
}

# ── Charger les bibliothèques ────────────────────────────────────────────────
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/telegram.sh"

# Copies the UI primitives starter kit into the project. cp -rn (no-clobber)
# preserves per-project edits across re-runs: the starter kit is scaffolding,
# not a lock-step library.
inject_ui_primitives() {
  local pipeline_dir="$1"
  local src="${pipeline_dir}/templates/ui-primitives"
  local dst="${PROJECT_DIR}/ui-primitives"

  if [[ ! -d "$src" ]]; then
    log "WARN" "ui-primitives template missing at ${src}; skipping"
    return 0
  fi

  mkdir -p "$dst"
  cp -rn "${src}/." "${dst}/" 2>/dev/null || true

  local count
  count=$(find "$dst/primitives" -name "*.tsx" 2>/dev/null | wc -l)
  log "INFO" "UI primitives starter kit present at ${dst} (${count} .tsx files)"
}

# Deterministic UUIDv5 per role so --session-id is stable across runs
# and --resume reliably finds the right session.
role_session_id() {
  local role="$1"
  python3 - <<PYEOF "$role"
import sys, uuid
print(uuid.uuid5(uuid.NAMESPACE_URL, f"{sys.argv[1]}.pipeline.hackathon"))
PYEOF
}

# ── Cleanup trap ─────────────────────────────────────────────────────────────
_cleanup() {
  rm -f "${LOCK_FILE:-}" 2>/dev/null || true
  rm -f /tmp/hackathon-cmd-*.sh /tmp/hackathon-prompt-*.txt /tmp/hackathon-*-??????.sh 2>/dev/null || true
}
trap _cleanup EXIT

# ── Lancer auto_setup avant tout le reste ───────────────────────────────────
if [[ "$DRY_RUN" != "1" ]]; then
  auto_setup
  interactive_config
fi

# ── Charger et valider la configuration ──────────────────────────────────────
load_config "${SCRIPT_DIR}/hackathon.conf"
if [[ "$DRY_RUN" != "1" ]]; then
  check_prereqs
fi
tg_init

# ── Logging setup ───────────────────────────────────────────────────────────
log_slug=$(echo "$HACKATHON_NAME" | sed -E 's/[^a-zA-Z0-9]+/-/g' | sed -E 's/^-+|-+$//g' | tr '[:upper:]' '[:lower:]')
log_slug="${log_slug:-unknown}"
LOG_DIR="${SCRIPT_DIR}/logs/${log_slug}"
mkdir -p "$LOG_DIR"

PIPELINE_LOG="$LOG_DIR/pipeline.log"
EVENTS_LOG="$LOG_DIR/events.log"

if [[ "$DRY_RUN" != "1" ]]; then
  exec > >(tee -a "$PIPELINE_LOG") 2>&1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') | PIPELINE_START | $HACKATHON_NAME" >> "$EVENTS_LOG"

if [[ "$DRY_RUN" != "1" ]]; then
# ── Lock file ───────────────────────────────────────────────────────────────
mkdir -p "$PROJECT_DIR"
LOCK_FILE="${PROJECT_DIR}/.pipeline.lock"
if [[ -f "$LOCK_FILE" ]]; then
  lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
  if kill -0 "$lock_pid" 2>/dev/null; then
    log "WARN" "Une autre session pipeline est active (PID: ${lock_pid})"
    log "WARN" "Supprime ${LOCK_FILE} si c'est une erreur."
    exit 1
  else
    log "WARN" "Lock file obsolète (PID: ${lock_pid}). Suppression."
    rm -f "$LOCK_FILE"
  fi
fi
echo $$ > "$LOCK_FILE"

# ── Orphan process sweep (defensive, narrow) ─────────────────────────────
# Prior failed runs may have left wrappers attached to dead tmux windows.
# This block kills ONLY processes matching our pipeline's specific cmdline
# patterns, and ONLY when we're certain no live tmux session owns them.
#
# Safety gates (all must be true):
#   1. Not in --attach mode (user is connecting to an existing session).
#   2. Not in --watch mode (user is observing an existing session).
#   3. No tmux session named "${TMUX_SESSION}" is alive (if one exists,
#      someone else or our own prior launch is running; do NOT sweep).
#   4. The wrapper cmdline pattern includes the full absolute path to
#      THIS pipeline's mcp-coord/orchestrator_wrapper.py (so we don't
#      kill wrappers belonging to a different checkout of this repo).
#   5. Only current user's processes (pgrep -U "$(id -u)").
#
# If any gate fails, we SKIP the sweep. A few orphans are harmless;
# killing the wrong process is not.

if [[ "${ATTACH_MODE:-false}" == "false" ]] \
  && [[ "${WATCH_MODE:-false}" == "false" ]] \
  && ! tmux has-session -t "${TMUX_SESSION}" 2>/dev/null
then
  # Build the precise pattern: absolute path + file name.
  wrapper_pattern="${SCRIPT_DIR}/mcp-coord/orchestrator_wrapper.py"
  server_pattern="${SCRIPT_DIR}/mcp-coord/server.py"

  # Enumerate orphans (current user only, absolute-path match):
  orphan_wrappers=$(pgrep -U "$(id -u)" -f "${wrapper_pattern}" 2>/dev/null || true)   # target: orchestrator_wrapper.py
  orphan_servers=$(pgrep -U "$(id -u)" -f "${server_pattern}" 2>/dev/null || true)     # target: server.py

  orphan_total=$(printf '%s\n%s\n' "$orphan_wrappers" "$orphan_servers" \
    | grep -c . || true)

  if (( orphan_total > 0 )); then
    log "INFO" "Found ${orphan_total} orphaned pipeline process(es) from a prior run"
    # Graceful first: SIGTERM, 5s grace
    if [[ -n "$orphan_wrappers" ]]; then
      log "INFO" "Sending SIGTERM to wrapper PIDs: $(echo "$orphan_wrappers" | tr '\n' ' ')"
      kill -TERM $orphan_wrappers 2>/dev/null || true
    fi
    if [[ -n "$orphan_servers" ]]; then
      log "INFO" "Sending SIGTERM to server PIDs: $(echo "$orphan_servers" | tr '\n' ' ')"
      kill -TERM $orphan_servers 2>/dev/null || true
    fi
    sleep 5

    # Any still alive → SIGKILL (last resort)
    still_wrappers=$(pgrep -U "$(id -u)" -f "${wrapper_pattern}" 2>/dev/null || true)
    still_servers=$(pgrep -U "$(id -u)" -f "${server_pattern}" 2>/dev/null || true)
    if [[ -n "$still_wrappers" || -n "$still_servers" ]]; then
      log "WARN" "Some orphans ignored SIGTERM; sending SIGKILL"
      [[ -n "$still_wrappers" ]] && kill -KILL $still_wrappers 2>/dev/null || true
      [[ -n "$still_servers" ]] && kill -KILL $still_servers 2>/dev/null || true
    fi
    log "INFO" "Orphan sweep complete"
  fi
else
  log "INFO" "Orphan sweep skipped (attach/watch mode, or tmux session alive)"
fi
# ─────────────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════════════"
echo "  Pipeline hackathon : ${HACKATHON_NAME}"
echo "════════════════════════════════════════════════════"
echo ""

# ── Initialiser le projet ────────────────────────────────────────────────────
git_init
ensure_github

# Copier les agents dans le projet
mkdir -p "${PROJECT_DIR}/.claude/agents"
cp "${SCRIPT_DIR}/agents/"*.md "${PROJECT_DIR}/.claude/agents/"
log "INFO" "Agents copiés dans .claude/agents/"

# Configurer les safeguards et permissions
setup_safeguards

# Générer CLAUDE.md
inject_claude_md "$SCRIPT_DIR"
inject_ui_primitives "$SCRIPT_DIR"

# Premier commit
git_checkpoint "setup initial : CLAUDE.md + agents"

tg_send "$(printf '🚀 *Pipeline hackathon lancé*\nProjet : `%s`\nDossier : `%s`' \
  "$HACKATHON_NAME" "$PROJECT_DIR")"
fi  # end DRY_RUN != 1

# ── Phase 1 : Ultraplan ─────────────────────────────────────────────────────
if [[ "$DRY_RUN" == "1" || "$SKIP_ULTRAPLAN" == "true" ]]; then
  log "INFO" "Ultraplan skipped"
else
  echo ""
  echo "════════════════════════════════════════════════════"
  echo "  ÉTAPE 1 : ULTRAPLAN"
  echo "════════════════════════════════════════════════════"
  echo ""
  echo "  Lance Claude Code dans un autre terminal :"
  echo ""
  echo "    cd ${PROJECT_DIR}"
  echo "    claude"
  echo ""
  echo "  Puis tape :"
  echo ""
  echo "    /ultraplan Lis CLAUDE.md. Planifie ce hackathon."
  echo ""
  echo "  Review le plan dans ton navigateur."
  echo "  Commente, itère, approuve."
  echo "  Choisis 'Teleport back to terminal'."
  echo "  Le plan sera sauvegardé dans docs/PLAN.md."
  echo ""

  if [[ "$TELEGRAM_ENABLED" == "true" ]]; then
    tg_send "$(printf '📋 *Ultraplan requis*\nOuvre un terminal et lance :\n`cd %s && claude`\nPuis tape : `/ultraplan Lis CLAUDE.md`\nRéponds "ok" ici quand le plan est approuvé.' \
      "$PROJECT_DIR")"
    tg_ask "Ultraplan approuvé ? Réponds 'ok' quand c'est fait." 7200 || true
    log "INFO" "Ultraplan approuvé via Telegram"
  else
    log "INFO" "En attente de docs/PLAN.md (lance /ultraplan dans un autre terminal)"
    wait_count=0
    while [[ ! -f "$PROJECT_DIR/docs/PLAN.md" ]]; do
      sleep 5
      wait_count=$((wait_count + 1))
      if [[ $wait_count -ge 720 ]]; then
        log "WARN" "Timeout 60min. Continuation sans plan."
        break
      fi
    done
    if [[ -f "$PROJECT_DIR/docs/PLAN.md" ]]; then
      log "INFO" "PLAN.md détecté. Ultraplan approuvé."
    fi
  fi

  git_checkpoint "ultraplan approuvé"
fi

# ── Phase 2 : 6-Window Parallel Orchestration ─────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════"
echo "  ÉTAPE 2 : ORCHESTRATION PARALLÈLE (6 fenêtres)"
echo "════════════════════════════════════════════════════"
echo ""

# ── Precondition checks ───────────────────────────────────────────────────────
check_launch_preconditions() {
  local errors=0

  if [[ ! -f "${SCRIPT_DIR}/mcp-coord/server.py" ]]; then
    log "ERROR" "mcp-coord/server.py not found"; errors=$((errors + 1))
  fi

  if [[ ! -f "${SCRIPT_DIR}/mcp-coord/requirements.txt" ]]; then
    log "ERROR" "mcp-coord/requirements.txt not found"; errors=$((errors + 1))
  fi

  # Ensure project .pipeline directory exists and holds a copy of the MCP
  # config template. The launcher jq-patches this copy with the venv Python
  # path; the repo's version is the clean template.
  mkdir -p "${PROJECT_DIR}/.pipeline"
  if [[ ! -f "${PROJECT_DIR}/.pipeline/mcp.json" ]]; then
    if [[ ! -f "${SCRIPT_DIR}/.pipeline/mcp.json" ]]; then
      log "ERROR" "Template mcp.json missing at ${SCRIPT_DIR}/.pipeline/mcp.json"
      errors=$((errors + 1))
    else
      cp "${SCRIPT_DIR}/.pipeline/mcp.json" "${PROJECT_DIR}/.pipeline/mcp.json"
      log "INFO" "Copied mcp.json template into ${PROJECT_DIR}/.pipeline/"
    fi
  fi

  if ! jq empty "${PROJECT_DIR}/.pipeline/mcp.json" 2>/dev/null; then
    log "ERROR" ".pipeline/mcp.json is not valid JSON"; errors=$((errors + 1))
  fi

  local role
  for role in supervisor delivery security quality; do
    if [[ ! -f "${SCRIPT_DIR}/.claude/orchestrators/${role}.prompt.md" ]]; then
      log "ERROR" "Missing orchestrator: .claude/orchestrators/${role}.prompt.md"
      errors=$((errors + 1))
    fi
  done

  local agent_count=0 f
  for f in "${SCRIPT_DIR}"/agents/*.md; do
    [[ -f "$f" ]] && agent_count=$((agent_count + 1))
  done
  if (( agent_count < 15 )); then
    log "ERROR" "Expected >=15 agent .md files in agents/, found ${agent_count}"
    errors=$((errors + 1))
  fi

  if ! claude --version &>/dev/null; then
    log "ERROR" "claude --version failed"; errors=$((errors + 1))
  fi

  if (( errors > 0 )); then
    log "ERROR" "${errors} precondition(s) failed. Cannot launch."
    exit 1
  fi
  log "INFO" "All launch preconditions passed"
}

if [[ "$DRY_RUN" != "1" ]]; then
  check_launch_preconditions
fi

# ── Determine MCP Python interpreter (venv preferred) ─────────────────────────
MCP_PY="${SCRIPT_DIR}/mcp-coord/.venv/bin/python3"
if [[ "$DRY_RUN" != "1" ]]; then
  if [[ ! -x "$MCP_PY" ]]; then
    if python3 -c "import mcp" 2>/dev/null; then
      MCP_PY="python3"
      log "INFO" "Venv unavailable; falling back to system python3 for MCP server"
    else
      log "ERROR" "mcp-coord venv not found at ${MCP_PY}."
      log "ERROR" "Run: cd mcp-coord && python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt"
      exit 1
    fi
  fi
  if ! "$MCP_PY" -c "import mcp" 2>/dev/null; then
    log "ERROR" "mcp module not importable from venv. Re-run pip install -r mcp-coord/requirements.txt inside the venv."
    exit 1
  fi
  log "INFO" "MCP Python interpreter: ${MCP_PY}"

  # ── Update mcp.json to use the correct Python interpreter ─────────────────────
  jq --arg py "$MCP_PY" --arg srv "${SCRIPT_DIR}/mcp-coord/server.py" '
    .mcpServers."pipeline-coordinator".command = $py |
    .mcpServers."pipeline-coordinator".args    = [$srv]
  ' "${PROJECT_DIR}/.pipeline/mcp.json" > "${PROJECT_DIR}/.pipeline/mcp.json.tmp" && \
    mv "${PROJECT_DIR}/.pipeline/mcp.json.tmp" "${PROJECT_DIR}/.pipeline/mcp.json"
  log "INFO" "mcp.json updated: command=${MCP_PY}"

  # ── Create pipeline directories ───────────────────────────────────────────────
  mkdir -p "${PROJECT_DIR}/.pipeline/logs"
  mkdir -p "${PROJECT_DIR}/.pipeline/heartbeat"
  mkdir -p "${PROJECT_DIR}/.pipeline/locks"
  mkdir -p "${PROJECT_DIR}/notes"
fi

# ── DRY_RUN short-circuit ─────────────────────────────────────────────────────
# When DRY_RUN=1, print the exact tmux commands that would execute, then exit.
if [[ "$DRY_RUN" == "1" ]]; then
  echo "DRY_RUN=1 — printing planned tmux commands (no real session created)"
  echo ""
  echo "WINDOW 0 (mcp):       ${MCP_PY} ${SCRIPT_DIR}/mcp-coord/server.py"
  echo "WINDOW 1 (bootstrap): claude -p <bootstrap.prompt.md> --session-id $(role_session_id bootstrap) --name bootstrap --model ${CLAUDE_MODEL} --effort ${CLAUDE_EFFORT} --mcp-config ${PROJECT_DIR}/.pipeline/mcp.json --output-format stream-json --verbose --permission-mode default"
  echo "WINDOW 2 (supervisor): ${MCP_PY} ${SCRIPT_DIR}/mcp-coord/orchestrator_wrapper.py --role supervisor --session-id $(role_session_id supervisor) --prompt-file ${SCRIPT_DIR}/.claude/orchestrators/supervisor.prompt.md --mcp-config ${PROJECT_DIR}/.pipeline/mcp.json --log-file ${PROJECT_DIR}/.pipeline/logs/supervisor.jsonl --heartbeat-file ${PROJECT_DIR}/.pipeline/heartbeat/supervisor.txt --model ${CLAUDE_MODEL} --effort ${CLAUDE_EFFORT} --cycle-seconds 60"
  echo "WINDOW 3 (delivery):  ${MCP_PY} ${SCRIPT_DIR}/mcp-coord/orchestrator_wrapper.py --role delivery --session-id $(role_session_id delivery) --prompt-file ${SCRIPT_DIR}/.claude/orchestrators/delivery.prompt.md --mcp-config ${PROJECT_DIR}/.pipeline/mcp.json --log-file ${PROJECT_DIR}/.pipeline/logs/delivery.jsonl --heartbeat-file ${PROJECT_DIR}/.pipeline/heartbeat/delivery.txt --model ${CLAUDE_MODEL} --effort ${CLAUDE_EFFORT} --cycle-seconds 60"
  echo "WINDOW 4 (security):  ${MCP_PY} ${SCRIPT_DIR}/mcp-coord/orchestrator_wrapper.py --role security --session-id $(role_session_id security) --prompt-file ${SCRIPT_DIR}/.claude/orchestrators/security.prompt.md --mcp-config ${PROJECT_DIR}/.pipeline/mcp.json --log-file ${PROJECT_DIR}/.pipeline/logs/security.jsonl --heartbeat-file ${PROJECT_DIR}/.pipeline/heartbeat/security.txt --model ${CLAUDE_MODEL} --effort ${CLAUDE_EFFORT} --cycle-seconds 60"
  echo "WINDOW 5 (quality):   ${MCP_PY} ${SCRIPT_DIR}/mcp-coord/orchestrator_wrapper.py --role quality --session-id $(role_session_id quality) --prompt-file ${SCRIPT_DIR}/.claude/orchestrators/quality.prompt.md --mcp-config ${PROJECT_DIR}/.pipeline/mcp.json --log-file ${PROJECT_DIR}/.pipeline/logs/quality.jsonl --heartbeat-file ${PROJECT_DIR}/.pipeline/heartbeat/quality.txt --model ${CLAUDE_MODEL} --effort ${CLAUDE_EFFORT} --cycle-seconds 60"
  echo ""
  echo "DRY_RUN complete — exiting without launching tmux."
  exit 0
fi

# ── Kill any previous hackathon session ───────────────────────────────────────
tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true

# ── Helper: launch a claude orchestrator as a tmux window ─────────────────────
# Bootstrap: one-shot `claude -p` (exits after producing research artefacts).
# Long-running roles (supervisor, delivery, security, quality): persistent
# Python wrapper that feeds `claude --input-format stream-json` with periodic
# continue messages.
# Usage: launch_claude_window <role> <prompt_file>
launch_claude_window() {
  local role="$1"
  local prompt_file="$2"
  local log_file="${PROJECT_DIR}/.pipeline/logs/${role}.jsonl"

  local session_uuid
  session_uuid=$(role_session_id "$role")

  # Bootstrap stays one-shot (plain -p)
  if [[ "$role" == "bootstrap" ]]; then
    local cmd_file
    cmd_file=$(mktemp "/tmp/hackathon-${role}-XXXXXX.sh")
    chmod +x "$cmd_file"

    cat > "$cmd_file" <<LAUNCHER_EOF
#!/bin/bash
set -uo pipefail
rm -f '${cmd_file}'
cd '${PROJECT_DIR}'
exec claude -p \\
  --session-id '${session_uuid}' \\
  --name '${role}' \\
  --model '${CLAUDE_MODEL}' --effort '${CLAUDE_EFFORT}' \\
  --mcp-config '${PROJECT_DIR}/.pipeline/mcp.json' \\
  --output-format stream-json --verbose \\
  --permission-mode default \\
  < '${prompt_file}'
LAUNCHER_EOF

    tmux new-window -t "${TMUX_SESSION}" -n "${role}" "${cmd_file}"
    tmux pipe-pane -t "${TMUX_SESSION}:${role}" -o "tee -a '${log_file}'"
    log "INFO" "Launched window '${role}'"
    return
  fi

  # Long-running orchestrators: use the streaming-input wrapper
  tmux new-window -t "${TMUX_SESSION}" -n "${role}" \
    "cd '${PROJECT_DIR}' && exec '${MCP_PY}' \
       '${SCRIPT_DIR}/mcp-coord/orchestrator_wrapper.py' \
       --role '${role}' \
       --session-id '${session_uuid}' \
       --prompt-file '${prompt_file}' \
       --mcp-config '${PROJECT_DIR}/.pipeline/mcp.json' \
       --log-file '${log_file}' \
       --heartbeat-file '${PROJECT_DIR}/.pipeline/heartbeat/${role}.txt' \
       --model '${CLAUDE_MODEL}' \
       --effort '${CLAUDE_EFFORT}' \
       --cycle-seconds 60"
  log "INFO" "Launched window '${role}'"
}

# ── Launch-phase cleanup (Ctrl+C while windows are starting) ──────────────────
_launch_phase_cleanup() {
  log "WARN" "Interrupted during launch phase — cleaning up"
  local i
  for i in 0 1 2 3 4 5; do
    tmux kill-window -t "${TMUX_SESSION}:${i}" 2>/dev/null || true
  done
  tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
}
trap _launch_phase_cleanup SIGINT SIGTERM

# ── Launch 6 tmux windows ─────────────────────────────────────────────────────

# window 0 : MCP coordination server
log "INFO" "Launching window 0 (mcp)"
tmux new-session -d -s "$TMUX_SESSION" -n mcp \
  "cd '${PROJECT_DIR}' && exec '${MCP_PY}' '${SCRIPT_DIR}/mcp-coord/server.py' \
   >> '${PROJECT_DIR}/.pipeline/mcp-server.stdout' \
   2>> '${PROJECT_DIR}/.pipeline/mcp-server.stderr'"

# Brief pause so the MCP server can bind its port before clients connect
sleep 2

# window 1 : bootstrap (one-shot — exits after producing research artefacts)
launch_claude_window "bootstrap" \
  "${SCRIPT_DIR}/.claude/orchestrators/bootstrap.prompt.md"

# window 2 : supervisor
launch_claude_window "supervisor" \
  "${SCRIPT_DIR}/.claude/orchestrators/supervisor.prompt.md"

# window 3 : delivery
launch_claude_window "delivery" \
  "${SCRIPT_DIR}/.claude/orchestrators/delivery.prompt.md"

# window 4 : security
launch_claude_window "security" \
  "${SCRIPT_DIR}/.claude/orchestrators/security.prompt.md"

# window 5 : quality
launch_claude_window "quality" \
  "${SCRIPT_DIR}/.claude/orchestrators/quality.prompt.md"

log "INFO" "All 6 windows launched in tmux session '${TMUX_SESSION}'"
tg_send "$(printf '🤖 *Orchestration parallèle lancée*\n6 fenêtres tmux actives.\nSession : `%s`' \
  "$TMUX_SESSION")"

echo ""
echo "════════════════════════════════════════════════════"
echo "  Pipeline actif dans tmux (6 fenêtres)"
echo ""
echo "  Pour voir :    tmux attach -t ${TMUX_SESSION}"
echo "  Pour détacher : Ctrl+B puis D"
echo "  Pour watch :   ./hackathon.sh --watch"
echo ""
echo "  Fenêtres : mcp | bootstrap | supervisor |"
echo "             delivery | security | quality"
echo "════════════════════════════════════════════════════"
echo ""

# ── Watchdog helpers ──────────────────────────────────────────────────────────

check_window_alive() {
  tmux list-windows -t "$TMUX_SESSION" -F '#W' 2>/dev/null | grep -qx "$1"
}

check_pane_dead() {
  local dead
  dead=$(tmux display-message -t "${TMUX_SESSION}:$1" -p '#{pane_dead}' 2>/dev/null) || return 1
  [[ "$dead" == "1" ]]
}

get_pane_exit_code() {
  tmux display-message -t "${TMUX_SESSION}:$1" -p '#{pane_dead_status}' 2>/dev/null || echo ""
}

check_heartbeat_fresh() {
  local hb_file="${PROJECT_DIR}/.pipeline/heartbeat/$1.txt"
  [[ -f "$hb_file" ]] || return 1
  local mtime now
  mtime=$(stat -c %Y "$hb_file" 2>/dev/null) || return 1
  now=$(date +%s)
  (( (now - mtime) < 120 ))
}

check_mcp_memory() {
  local pid
  pid=$(tmux display-message -t "${TMUX_SESSION}:mcp" -p '#{pane_pid}' 2>/dev/null) || return 0
  if [[ -n "$pid" ]] && [[ -f "/proc/${pid}/status" ]]; then
    local vmrss
    vmrss=$(awk '/^VmRSS:/ {print $2}' "/proc/${pid}/status" 2>/dev/null) || return 0
    if [[ -n "$vmrss" ]] && (( vmrss > 1048576 )); then
      log "WARN" "MCP server memory: ${vmrss}KB (>1GB)"
    fi
  fi
}

respawn_mcp() {
  log "INFO" "Respawning MCP server"
  tmux respawn-window -k -t "${TMUX_SESSION}:mcp" \
    "cd '${PROJECT_DIR}' && exec '${MCP_PY}' '${SCRIPT_DIR}/mcp-coord/server.py' \
     >> '${PROJECT_DIR}/.pipeline/mcp-server.stdout' \
     2>> '${PROJECT_DIR}/.pipeline/mcp-server.stderr'"
  sleep 2
}

respawn_role() {
  local role="$1"

  # Bootstrap is one-shot; never respawn it
  if [[ "$role" == "bootstrap" ]]; then
    return
  fi

  local log_file="${PROJECT_DIR}/.pipeline/logs/${role}.jsonl"
  local session_uuid
  session_uuid=$(role_session_id "$role")

  # Respawn via the streaming-input wrapper. The wrapper detects the
  # existing log file and uses --resume instead of --session-id, so the
  # claude subprocess resumes the prior conversation.
  local cmd="cd '${PROJECT_DIR}' && exec '${MCP_PY}' \
    '${SCRIPT_DIR}/mcp-coord/orchestrator_wrapper.py' \
    --role '${role}' \
    --session-id '${session_uuid}' \
    --prompt-file '${SCRIPT_DIR}/.claude/orchestrators/${role}.prompt.md' \
    --mcp-config '${PROJECT_DIR}/.pipeline/mcp.json' \
    --log-file '${log_file}' \
    --heartbeat-file '${PROJECT_DIR}/.pipeline/heartbeat/${role}.txt' \
    --model '${CLAUDE_MODEL}' \
    --effort '${CLAUDE_EFFORT}' \
    --cycle-seconds 60"

  if check_window_alive "$role"; then
    tmux respawn-window -k -t "${TMUX_SESSION}:${role}" "$cmd"
  else
    tmux new-window -t "${TMUX_SESSION}" -n "${role}" "$cmd"
  fi
  log "INFO" "Respawned ${role} via wrapper (--resume)"
}

# ── Graceful shutdown handler (SIGINT / SIGTERM) ──────────────────────────────
graceful_shutdown() {
  log "INFO" "Shutdown signal received — requesting graceful stop"

  if [[ -f "${SCRIPT_DIR}/mcp-coord/client_helper.py" ]]; then
    "$MCP_PY" "${SCRIPT_DIR}/mcp-coord/client_helper.py" post_message \
      --from user --to supervisor --topic shutdown 2>/dev/null || true
  fi

  local deadline
  deadline=$(( $(date +%s) + 120 ))
  while (( $(date +%s) < deadline )); do
    local alive=0 r
    for r in supervisor delivery security quality; do
      if check_window_alive "$r"; then
        alive=$((alive + 1))
      fi
    done
    if (( alive == 0 )); then
      log "INFO" "All orchestrators exited gracefully"
      break
    fi
    sleep 5
  done

  tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
  rm -f "${PROJECT_DIR}/.pipeline/locks/"* 2>/dev/null || true

  log "INFO" "Pipeline shutdown complete"
  tg_send "Pipeline arrêté proprement"
  exit 0
}

# Switch from launch-phase trap to watchdog trap
trap graceful_shutdown SIGINT SIGTERM

# Redact common secret patterns before forwarding to external channels.
# Not exhaustive — defense in depth, not sole defense. The upstream
# prompt rule "no secrets in STATUS.md" is the primary guard.
_redact_secrets() {
  local input="$1"
  # API key prefixes we know (extend as needed):
  input=$(printf '%s' "$input" | sed -E '
    s/(hc_live_[A-Za-z0-9_]{4})[A-Za-z0-9_]{8,}([A-Za-z0-9_]{4})/\1…REDACTED…\2/g
    s/(hc_test_[A-Za-z0-9_]{4})[A-Za-z0-9_]{8,}([A-Za-z0-9_]{4})/\1…REDACTED…\2/g
    s/(sk-[A-Za-z0-9_]{4})[A-Za-z0-9_]{8,}([A-Za-z0-9_]{4})/\1…REDACTED…\2/g
    s/(ghp_[A-Za-z0-9]{4})[A-Za-z0-9]{8,}([A-Za-z0-9]{4})/\1…REDACTED…\2/g
    s/(pk_[A-Za-z0-9_]{4})[A-Za-z0-9_]{8,}([A-Za-z0-9_]{4})/\1…REDACTED…\2/g
    s/(xox[bpsa]-[A-Za-z0-9-]{4})[A-Za-z0-9-]{8,}([A-Za-z0-9-]{4})/\1…REDACTED…\2/g
    s/(glpat-[A-Za-z0-9_-]{4})[A-Za-z0-9_-]{8,}([A-Za-z0-9_-]{4})/\1…REDACTED…\2/g
    s/(AKIA[A-Z0-9]{4})[A-Z0-9]{8,}([A-Z0-9]{4})/\1…REDACTED…\2/g
    s/([A-Z_]*(SECRET|TOKEN|PASSWORD|APIKEY|API_KEY)[A-Z_]*[[:space:]]*=[[:space:]]*)([^[:space:]]+)/\1***REDACTED***/gi
  ')
  printf '%s' "$input"
}

# ── Per-role watchdog with exponential backoff ────────────────────────────────
# Every 30s: check each role's window, pane liveness, and heartbeat freshness.
# Respawn dead roles via claude --resume. Backoff: 30 → 60 → 120 → 300s.
# Exit code 42 = context-pressure checkpoint → immediate resume, no backoff.
# Bootstrap is one-shot (exit 0 expected). MCP is restarted first if down.

echo "Surveillance active (6 fenêtres). Ctrl+C pour arrêt propre."
echo ""

ORCHESTRATOR_ROLES=(supervisor delivery security quality)
BOOTSTRAP_DONE=false
WATCHDOG_START=$(date +%s)
HB_GRACE_UNTIL=$((WATCHDOG_START + 60))

declare -A ROLE_BACKOFF
declare -A ROLE_LAST_RESTART
declare -A ROLE_STABLE_SINCE

for _wd_role in "${ORCHESTRATOR_ROLES[@]}"; do
  ROLE_BACKOFF[$_wd_role]=30
  ROLE_LAST_RESTART[$_wd_role]=0
  ROLE_STABLE_SINCE[$_wd_role]=$WATCHDOG_START
done

while true; do
  sleep 30

  now=$(date +%s)

  # ── Session-level check ─────────────────────────────────────────────────
  if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    log "ERROR" "tmux session '${TMUX_SESSION}' gone — exiting watchdog"
    break
  fi

  # ── Forward new HUMAN_INPUT_NEEDED to Telegram (every 3 cycles) ──────────
  # Debounce: check every 3rd watchdog cycle (~90s at 30s cycle).
  # Content-hash-based dedup: only forward when the HUMAN_INPUT_NEEDED
  # section has changed since last send.
  # Baseline: on first check (no hash file), record hash but don't send
  # (avoid dumping the full file on init).
  # Sanitization: secrets redacted before send. Primary guard remains the
  # orchestrator prompts ("never put secrets in STATUS.md"); this is
  # defense in depth for known API-key prefixes only.
  # Rate: max 1 Telegram message per 90s by construction — well under
  # Telegram's 1 msg/sec/chat limit.
  if [[ "${TELEGRAM_ENABLED:-false}" == "true" ]]; then
    : "${_wd_cycle:=0}"
    _wd_cycle=$((_wd_cycle + 1))
    if (( _wd_cycle % 3 == 0 )); then
      _status_file="${PROJECT_DIR}/docs/STATUS.md"
      _hash_file="${PROJECT_DIR}/.pipeline/last-human-input-hash"
      if [[ -f "$_status_file" ]]; then
        # Extract the HUMAN_INPUT_NEEDED section (from its header to
        # the next "## " header or EOF).
        _block=$(awk '
          /^## HUMAN_INPUT_NEEDED/{flag=1; next}
          /^## /{if(flag) exit}
          flag {print}
        ' "$_status_file" | sed '/^[[:space:]]*$/d') || _block=""

        if [[ -n "$_block" ]]; then
          _hash=$(printf '%s' "$_block" | sha1sum 2>/dev/null | awk '{print $1}') || _hash=""
          _prev_hash=$(cat "$_hash_file" 2>/dev/null || echo "")

          if [[ -z "$_prev_hash" ]]; then
            # First-ever check — baseline only, do not send.
            echo "$_hash" > "$_hash_file" 2>/dev/null || true
            log "INFO" "Telegram HUMAN_INPUT baseline recorded"
          elif [[ "$_hash" != "$_prev_hash" ]]; then
            # Content changed — sanitize + truncate + send.
            _sanitized=$(_redact_secrets "$_block")
            # Truncate to 3800 bytes (leaves headroom under Telegram's
            # 4096-char sendMessage limit). head -c is byte-based; a
            # multi-byte UTF-8 char at the boundary may be cut mid-
            # sequence — acceptable since the "truncated" notice makes
            # any garbled tail visible rather than silent.
            _truncated=$(printf '%s' "$_sanitized" | head -c 3800)
            if [[ "${#_sanitized}" -gt 3800 ]]; then
              _truncated="${_truncated}

…(truncated; see docs/STATUS.md on the host for full details)"
            fi
            _message="⚠️ HUMAN INPUT NEEDED (${HACKATHON_NAME:-pipeline})

${_truncated}"
            # tg_send is graceful — failures don't crash watchdog.
            tg_send "$_message" 2>/dev/null || \
              log "WARN" "Telegram forward failed (network? rate?); will retry next cycle"
            echo "$_hash" > "$_hash_file" 2>/dev/null || true
          fi
          # else: unchanged; no action
        fi
      fi
    fi
  fi
  # ─────────────────────────────────────────────────────────────────────────

  # ── MCP server (check first — orchestrators depend on it) ──────────────
  if ! check_window_alive "mcp" || check_pane_dead "mcp"; then
    log "WARN" "MCP server down — restarting before orchestrators"
    respawn_mcp
  else
    check_mcp_memory
  fi

  # ── Bootstrap (one-shot; graceful exit is success, not a crash) ─────────
  if [[ "$BOOTSTRAP_DONE" == "false" ]]; then
    if ! check_window_alive "bootstrap" || check_pane_dead "bootstrap"; then
      BOOTSTRAP_DONE=true
      log "INFO" "Bootstrap exited (expected one-shot completion)"
    fi
  fi

  # ── Orchestrator roles ──────────────────────────────────────────────────
  all_exited=true
  for wd_role in "${ORCHESTRATOR_ROLES[@]}"; do

    # — Window gone entirely —
    if ! check_window_alive "$wd_role"; then
      current_backoff=${ROLE_BACKOFF[$wd_role]}
      last_restart=${ROLE_LAST_RESTART[$wd_role]}
      if (( last_restart > 0 && (now - last_restart) < current_backoff )); then
        all_exited=false
        continue
      fi

      respawn_role "$wd_role"

      if (( current_backoff < 60 ));  then ROLE_BACKOFF[$wd_role]=60
      elif (( current_backoff < 120 )); then ROLE_BACKOFF[$wd_role]=120
      elif (( current_backoff < 300 )); then ROLE_BACKOFF[$wd_role]=300
      fi

      ROLE_STABLE_SINCE[$wd_role]=$now
      tg_send "$(printf '⚠️ *%s* relancé (window gone)' "$wd_role")"
      all_exited=false
      continue
    fi

    all_exited=false

    # — Pane dead (window still exists) —
    if check_pane_dead "$wd_role"; then
      exit_code=$(get_pane_exit_code "$wd_role")

      # Exit 42 = context-pressure checkpoint → immediate resume
      if [[ "$exit_code" == "42" ]]; then
        log "INFO" "${wd_role} exited 42 (context pressure) — immediate resume"
        respawn_role "$wd_role"
        ROLE_STABLE_SINCE[$wd_role]=$now
        continue
      fi

      # Exit 0 = graceful
      [[ "$exit_code" == "0" ]] && continue

      # Other codes = crash
      log "WARN" "${wd_role} pane dead (exit ${exit_code:-?})"
      current_backoff=${ROLE_BACKOFF[$wd_role]}
      last_restart=${ROLE_LAST_RESTART[$wd_role]}
      if (( last_restart > 0 && (now - last_restart) < current_backoff )); then
        continue
      fi

      respawn_role "$wd_role"

      if (( current_backoff < 60 ));  then ROLE_BACKOFF[$wd_role]=60
      elif (( current_backoff < 120 )); then ROLE_BACKOFF[$wd_role]=120
      elif (( current_backoff < 300 )); then ROLE_BACKOFF[$wd_role]=300
      fi

      ROLE_STABLE_SINCE[$wd_role]=$now
      tg_send "$(printf '⚠️ *%s* relancé (exit %s)' "$wd_role" "${exit_code:-?}")"
      continue
    fi

    # — Alive: check heartbeat (skip during initial grace period) —
    if (( now > HB_GRACE_UNTIL )); then
      if ! check_heartbeat_fresh "$wd_role"; then
        current_backoff=${ROLE_BACKOFF[$wd_role]}
        last_restart=${ROLE_LAST_RESTART[$wd_role]}
        if (( last_restart > 0 && (now - last_restart) < current_backoff )); then
          continue
        fi

        log "WARN" "${wd_role} heartbeat stale (>120s)"
        respawn_role "$wd_role"

        if (( current_backoff < 60 ));  then ROLE_BACKOFF[$wd_role]=60
        elif (( current_backoff < 120 )); then ROLE_BACKOFF[$wd_role]=120
        elif (( current_backoff < 300 )); then ROLE_BACKOFF[$wd_role]=300
        fi

        ROLE_STABLE_SINCE[$wd_role]=$now
        tg_send "$(printf '⚠️ *%s* heartbeat stale — relancé' "$wd_role")"
        continue
      fi
    fi

    # — Stable: reset backoff after 5 min —
    stable_since=${ROLE_STABLE_SINCE[$wd_role]}
    if (( now - stable_since > 300 && ROLE_BACKOFF[$wd_role] > 30 )); then
      ROLE_BACKOFF[$wd_role]=30
      ROLE_LAST_RESTART[$wd_role]=0
      log "INFO" "${wd_role} stable 5+ min — backoff reset"
    fi
  done

  # ── All orchestrators exited gracefully → pipeline complete ─────────────
  if [[ "$all_exited" == "true" ]] && [[ "$BOOTSTRAP_DONE" == "true" ]]; then
    log "INFO" "All orchestrators have exited — pipeline complete"

    tmux kill-window -t "${TMUX_SESSION}:mcp" 2>/dev/null || true
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
    rm -f "${PROJECT_DIR}/.pipeline/locks/"* 2>/dev/null || true

    tg_send "Pipeline terminé"

    echo ""
    echo "════════════════════════════════════════════════════"
    echo "  Pipeline terminé"
    echo "════════════════════════════════════════════════════"
    echo ""
    exit 0
  fi
done
