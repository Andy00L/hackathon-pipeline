#!/usr/bin/env bash
set -euo pipefail
# ============================================================================
# hackathon.sh — Point d'entrée du pipeline hackathon autonome
#
# Usage :
#   ./hackathon.sh                  Lance le pipeline complet
#   ./hackathon.sh --skip-ultraplan Skip ultraplan, direct Agent Teams
#   ./hackathon.sh --attach         Attach à la session tmux existante
#
# Au premier lancement, auto_setup() installe automatiquement tous les
# prérequis : outils système, GitHub CLI, plugins Claude Code, NOPASSWD sudo.
# Ensuite, il ne reste qu'à remplir hackathon.conf et déposer les inputs.
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMUX_SESSION="hackathon"

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
    echo "  → Configuration de NOPASSWD sudo..."
    echo "    (dernière fois qu'un mot de passe sudo sera demandé)"
    echo "$(whoami) ALL=(ALL) NOPASSWD: ALL" | sudo tee "/etc/sudoers.d/$(whoami)" > /dev/null
    sudo chmod 0440 "/etc/sudoers.d/$(whoami)"
    echo "  ✓ NOPASSWD sudo configuré"
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
    if [[ -d "$PROJECT_DIR" ]]; then
      project_resolved=$(cd "$PROJECT_DIR" && pwd)
    else
      mkdir -p "$PROJECT_DIR" 2>/dev/null
      if [[ -d "$PROJECT_DIR" ]]; then
        project_resolved=$(cd "$PROJECT_DIR" && pwd)
        rmdir "$PROJECT_DIR" 2>/dev/null || true
      else
        echo "  Impossible de créer $PROJECT_DIR. Utilisation du défaut."
        PROJECT_DIR="$default_project"
        mkdir -p "$PROJECT_DIR" 2>/dev/null
        project_resolved=$(cd "$PROJECT_DIR" && pwd)
        rmdir "$PROJECT_DIR" 2>/dev/null || true
      fi
    fi

    if [[ "$project_resolved" == "$SCRIPT_DIR" || "$project_resolved" == "$SCRIPT_DIR"/* ]]; then
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
  mkdir -p "${PROJECT_DIR}/.claude"

  local safeguards
  safeguards=$(cat <<'SAFEGUARDS_EOF'
{
  "permissions": {
    "deny": [
      "Bash(gh repo delete *)",
      "Bash(gh repo archive *)",
      "Bash(gh repo edit *)",
      "Bash(git push --force *)",
      "Bash(git push * --force)",
      "Bash(git push --force-with-lease *)",
      "Bash(rm -rf /)",
      "Bash(rm -rf ~)",
      "Bash(rm -rf /*)"
    ],
    "allow": [
      "Bash(gh repo create *)",
      "Bash(gh repo view *)",
      "Bash(git push origin *)",
      "Bash(git remote add *)",
      "Bash(git add *)",
      "Bash(git commit *)",
      "Bash(git log *)",
      "Bash(git diff *)",
      "Bash(git status *)",
      "Bash(git tag *)"
    ]
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "INPUT=$(cat); if echo \"$INPUT\" | jq -r '.input.command // empty' 2>/dev/null | grep -qiE 'gh repo delete|gh repo archive|gh repo edit|git push.*--force|rm -rf /|rm -rf ~|/mnt/c/|/mnt/d/|/mnt/e/'; then echo '{\"decision\": \"block\", \"reason\": \"Commande bloquée par safeguard hackathon\"}'; else echo '{\"decision\": \"allow\"}'; fi"
          }
        ]
      }
    ]
  },
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  }
}
SAFEGUARDS_EOF
)

  if [[ -f "$settings_file" ]]; then
    # Merge intelligent : union deny/allow, remplacer hooks, fusionner env
    local merged
    merged=$(jq --argjson sg "$safeguards" '
      .permissions.deny = ((.permissions.deny // []) + $sg.permissions.deny | unique) |
      .permissions.allow = ((.permissions.allow // []) + $sg.permissions.allow | unique) |
      .hooks.PreToolUse = $sg.hooks.PreToolUse |
      .env = ((.env // {}) + $sg.env)
    ' "$settings_file")
    echo "$merged" > "$settings_file"
  else
    echo "$safeguards" > "$settings_file"
  fi

  log "INFO" "Safeguards GitHub configurés"
}

# ── Lancer auto_setup avant tout le reste ───────────────────────────────────
auto_setup

# ── Charger les bibliothèques ────────────────────────────────────────────────
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/telegram.sh"

# ── Parse des arguments ──────────────────────────────────────────────────────
SKIP_ULTRAPLAN=false
ATTACH_ONLY=false
WATCH_MODE=false

for arg in "$@"; do
  case "$arg" in
    --skip-ultraplan) SKIP_ULTRAPLAN=true ;;
    --attach)         ATTACH_ONLY=true ;;
    --watch)          WATCH_MODE=true ;;
    --help|-h)
      echo "Usage: $0 [--skip-ultraplan] [--attach] [--watch]"
      echo ""
      echo "  --skip-ultraplan  Saute la phase ultraplan (si plan déjà fait)"
      echo "  --attach          Attach à la session tmux existante"
      echo "  --watch           Affiche les logs en temps réel (filtré)"
      exit 0
      ;;
  esac
done

# ── Attach mode ──────────────────────────────────────────────────────────────
if [[ "$ATTACH_ONLY" == "true" ]]; then
  if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    tmux attach -t "$TMUX_SESSION"
  else
    echo "Aucune session tmux '${TMUX_SESSION}' active."
    exit 1
  fi
  exit 0
fi

# ── Configuration interactive (si nécessaire) ────────────────────────────────
interactive_config

# ── Charger et valider la configuration ──────────────────────────────────────
load_config "${SCRIPT_DIR}/hackathon.conf"
check_prereqs
tg_init

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
if [[ "$SKIP_ULTRAPLAN" != "true" ]]; then
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

  tg_send "$(printf '📋 *Ultraplan requis*\nOuvre un terminal et lance :\n`cd %s && claude`\nPuis tape : `/ultraplan Lis CLAUDE.md`\nRéponds "ok" ici quand le plan est approuvé.' \
    "$PROJECT_DIR")"

  # Attendre confirmation
  if [[ "$TELEGRAM_ENABLED" == "true" ]]; then
    echo "  En attente de ta confirmation sur Telegram..."
    echo "  (ou appuie sur Entrée ici quand ultraplan est approuvé)"
    # Polling Telegram en background pendant qu'on attend aussi Entrée
    (
      response=$(tg_ask "Ultraplan approuvé ? Réponds 'ok' quand c'est fait." 7200)
      if [[ -n "$response" ]]; then
        touch "${PROJECT_DIR}/.ultraplan-done"
      fi
    ) &
    TG_WAIT_PID=$!

    # Attendre soit Entrée soit le fichier marker
    while true; do
      if [[ -f "${PROJECT_DIR}/.ultraplan-done" ]]; then
        rm -f "${PROJECT_DIR}/.ultraplan-done"
        kill "$TG_WAIT_PID" 2>/dev/null || true
        break
      fi
      if read -t 2 -r; then
        kill "$TG_WAIT_PID" 2>/dev/null || true
        break
      fi
    done
  else
    read -rp "  Appuie sur Entrée quand ultraplan est approuvé..."
  fi

  log "INFO" "Ultraplan approuvé"
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

# Permission mode
CLAUDE_CMD+=" --permission-mode acceptEdits"

# Créer le prompt initial
INITIAL_PROMPT='Lis CLAUDE.md attentivement.

Tu es le Lead du hackathon. Commence MAINTENANT :

1. Phase de recherche compétitive (WebSearch + WebFetch)
   Sauvegarde dans docs/COMPETITIVE-ANALYSIS.md

2. Si docs/PLAN.md existe (de ultraplan), utilise-le comme base.
   Sinon, crée ton propre plan dans docs/PLAN.md.

3. Crée ton équipe de 4 teammates :
   - Architecte (valide les choix techniques)
   - Implémenteur (code production-quality)
   - Sécurité (audit continu)
   - Qualité (évaluation /50)
   Les fichiers agents sont dans .claude/agents/.

4. Coordonne le travail. Itère sans limite.
   Objectif : score qualité >= 45/50 + sécurité PASS.

5. Quand le consensus est atteint : tag, zip, notifie.

La qualité est la SEULE priorité. Pas de compromis.'

# Lancer la session tmux
tmux new-session -d -s "$TMUX_SESSION" -c "$PROJECT_DIR"

# Envoyer la commande Claude dans tmux
tmux send-keys -t "$TMUX_SESSION" "export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 && ${CLAUDE_CMD}" Enter

# Attendre que Claude démarre (le prompt interactif)
sleep 8

# Envoyer le prompt initial
tmux send-keys -t "$TMUX_SESSION" "$INITIAL_PROMPT" Enter

# Activer le logging temps réel de la session tmux
LIVE_LOG="${PROJECT_DIR}/.pipeline-live.log"
: > "$LIVE_LOG"
tmux pipe-pane -t "$TMUX_SESSION" -o "cat >> ${LIVE_LOG}"
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

# Mode watch : afficher les logs filtrés en temps réel
if [[ "$WATCH_MODE" == "true" ]]; then
  echo "Mode watch activé. Ctrl+C pour quitter (la session tmux continue)."
  echo ""
  tail -f "${LIVE_LOG}" 2>/dev/null \
    | grep --line-buffered -iE \
      "feat:|fix:|test:|docs:|PASS|FAIL|READY|NOT READY|score|HUMAN_INPUT|error|warning|✓|✗|commit|phase|terminé|launched|relancé" \
    || true
  exit 0
fi

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

    tmux new-session -d -s "$TMUX_SESSION" -c "$PROJECT_DIR"
    tmux send-keys -t "$TMUX_SESSION" "export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 && ${CLAUDE_CMD}" Enter
    sleep 8
    tmux send-keys -t "$TMUX_SESSION" "La session précédente a été interrompue. Lis CLAUDE.md et docs/ pour comprendre l'état actuel. Vérifie le git log. Reprends où tu en étais. Continue jusqu'au consensus READY + PASS." Enter

    log "INFO" "Session relancée"
    tg_send "🔄 Session relancée avec succès"
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
