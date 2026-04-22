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
    local sudoers_file="/etc/sudoers.d/hackathon-$(whoami)"
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
  local templates_dir="${PROJECT_DIR}/templates/hooks"
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
      "Agent(scratch-tester)"
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
export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
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

# ── Cleanup trap ─────────────────────────────────────────────────────────────
_cleanup() {
  rm -f "${LOCK_FILE:-}" 2>/dev/null || true
  rm -f /tmp/hackathon-cmd-*.sh /tmp/hackathon-prompt-*.txt 2>/dev/null || true
}
trap _cleanup EXIT

# ── Lancer auto_setup avant tout le reste ───────────────────────────────────
auto_setup

# ── Configuration interactive (si nécessaire) ────────────────────────────────
interactive_config

# ── Charger et valider la configuration ──────────────────────────────────────
load_config "${SCRIPT_DIR}/hackathon.conf"
check_prereqs
tg_init

# ── Logging setup ───────────────────────────────────────────────────────────
log_slug=$(echo "$HACKATHON_NAME" | sed -E 's/[^a-zA-Z0-9]+/-/g' | sed -E 's/^-+|-+$//g' | tr '[:upper:]' '[:lower:]')
log_slug="${log_slug:-unknown}"
LOG_DIR="${SCRIPT_DIR}/logs/${log_slug}"
mkdir -p "$LOG_DIR"

PIPELINE_LOG="$LOG_DIR/pipeline.log"
CLAUDE_LOG="$LOG_DIR/claude-output.log"
EVENTS_LOG="$LOG_DIR/events.log"

exec > >(tee -a "$PIPELINE_LOG") 2>&1

echo "$(date '+%Y-%m-%d %H:%M:%S') | PIPELINE_START | $HACKATHON_NAME" >> "$EVENTS_LOG"

# ── Lock file ───────────────────────────────────────────────────────────────
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

# Premier commit
git_checkpoint "setup initial : CLAUDE.md + agents"

tg_send "$(printf '🚀 *Pipeline hackathon lancé*\nProjet : `%s`\nDossier : `%s`' \
  "$HACKATHON_NAME" "$PROJECT_DIR")"

# ── Phase 1 : Ultraplan ─────────────────────────────────────────────────────
if [[ "$SKIP_ULTRAPLAN" == "true" ]]; then
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

# ── Phase 2 : Agent Teams dans tmux ─────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════"
echo "  ÉTAPE 2 : LANCEMENT AGENT TEAMS"
echo "════════════════════════════════════════════════════"
echo ""

# Tuer une session existante si elle existe
tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true

# Construire la commande Claude
CLAUDE_CMD="claude --model ${CLAUDE_MODEL} --effort ${CLAUDE_EFFORT}"

# Ajouter Telegram channel si configuré
if [[ "$TELEGRAM_ENABLED" == "true" ]]; then
  CLAUDE_CMD+=" --channels plugin:telegram@claude-plugins-official"
fi

# Créer le prompt initial — PAS de parenthèses ni de caractères spéciaux bash
INITIAL_PROMPT='Lis CLAUDE.md attentivement.
Tu es le Lead du hackathon. Commence MAINTENANT.
1. Phase de recherche competitive via WebSearch et WebFetch, sauvegarde dans docs/COMPETITIVE-ANALYSIS.md
2. Si docs/PLAN.md existe, utilise-le comme base. Sinon, cree ton propre plan dans docs/PLAN.md.
3. Cree ton equipe de 4 teammates - Architecte, Implementeur, Securite, Qualite. Fichiers agents dans .claude/agents/.
4. Coordonne le travail. Itere sans limite. Objectif score qualite 45/50 minimum et securite PASS.
5. Quand le consensus est atteint, tag, zip, notifie.
La qualite est la SEULE priorite. Pas de compromis.'

# Prompt de relance — utilisé par le watchdog si la session crash
RESTART_PROMPT='Session interrompue. Lis CLAUDE.md et docs/ pour comprendre le contexte. Verifie git log. Reprends le travail. Continue sans limite.'

# Lancer Claude dans tmux (avec retry si échec de démarrage)
launch_attempts=0
while ! launch_claude_in_tmux "$INITIAL_PROMPT" "$TMUX_SESSION" "$PROJECT_DIR" "$CLAUDE_CMD"; do
  launch_attempts=$((launch_attempts + 1))
  if (( launch_attempts >= 3 )); then
    log "ERROR" "Claude n'a pas démarré après 3 tentatives. Abandon."
    tg_send "❌ Claude n'a pas pu démarrer après 3 tentatives."
    exit 1
  fi
  log "WARN" "Claude n'a pas démarré. Retry ${launch_attempts}/3..."
  tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
  sleep 5
done

# Activer le logging temps réel de la session tmux
LIVE_LOG="${PROJECT_DIR}/.pipeline-live.log"
: > "$LIVE_LOG"
tmux pipe-pane -t "$TMUX_SESSION" -o "tee -a ${CLAUDE_LOG} >> ${LIVE_LOG}"
log "INFO" "Logging temps réel activé : ${LIVE_LOG}"

log "INFO" "Agent Teams lancé dans tmux session '${TMUX_SESSION}'"
tg_send "$(printf '🤖 *Agent Teams lancé*\n5 agents Opus au travail.\nSession tmux : `%s`\nJe te ping si j'\''ai besoin de toi.' \
  "$TMUX_SESSION")"

echo ""
echo "════════════════════════════════════════════════════"
echo "  Pipeline actif dans tmux"
echo ""
echo "  Pour voir :    tmux attach -t ${TMUX_SESSION}"
echo "  Pour détacher : Ctrl+B puis D"
echo "  Pour watch :   ./hackathon.sh --watch"
echo "  Pour monitorer : Telegram"
echo ""
echo "  La session continue même si tu fermes ce terminal."
echo "  Claude itère sans limite jusqu'au consensus."
echo "════════════════════════════════════════════════════"
echo ""

# ── Boucle de surveillance (optionnelle) ─────────────────────────────────────
# Vérifie que la session tmux est toujours vivante
# Si elle crash, la relance avec --resume

echo "Surveillance active. Ctrl+C pour quitter (la session tmux continue)."
echo ""

restart_count=0
sleep_interval=60
last_restart_ts=0

while true; do
  sleep "$sleep_interval"

  if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    log "WARN" "Session tmux terminée ou crashée"

    # Vérifier si c'est une terminaison normale (hackathon fini)
    if [[ -f "${PROJECT_DIR}/docs/QUALITY-REPORT.md" ]]; then
      if grep -qi "READY" "${PROJECT_DIR}/docs/QUALITY-REPORT.md" 2>/dev/null; then
        log "INFO" "Le hackathon semble terminé (READY trouvé dans QUALITY-REPORT.md)"
        tg_send "✅ *Pipeline terminé normalement*"
        exit 0
      fi
    fi

    # Crash — relancer avec backoff exponentiel
    restart_count=$((restart_count + 1))
    sleep_interval=$((60 * (2 ** (restart_count - 1))))
    if (( sleep_interval > 300 )); then sleep_interval=300; fi

    log "WARN" "Relance de la session (tentative ${restart_count}, prochain check dans ${sleep_interval}s)..."
    tg_send "⚠️ Session interrompue. Relance automatique..."

    if launch_claude_in_tmux "$RESTART_PROMPT" "$TMUX_SESSION" "$PROJECT_DIR" "$CLAUDE_CMD"; then
      tmux pipe-pane -t "$TMUX_SESSION" -o "tee -a ${CLAUDE_LOG} >> ${LIVE_LOG}"
      log "INFO" "Session relancée"
      tg_send "🔄 Session relancée avec succès"
    else
      log "ERROR" "Claude n'a pas démarré après relance. Retry au prochain cycle."
      tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
      tg_send "❌ Claude n'a pas pu redémarrer. Retry au prochain cycle."
    fi
    last_restart_ts=$(date +%s)
  else
    # Session vivante — réinitialiser après 5+ min de stabilité
    if (( restart_count > 0 && last_restart_ts > 0 )); then
      now=$(date +%s)
      if (( now - last_restart_ts > 300 )); then
        restart_count=0
        sleep_interval=60
        last_restart_ts=0
        log "INFO" "Session stable depuis 5+ min, compteur de relance réinitialisé"
      fi
    else
      sleep_interval=60
    fi
  fi
done
