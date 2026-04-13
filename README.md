# Hackathon Pipeline

Pipeline autonome qui transforme un brief de hackathon en soumission complète.
5 agents Opus spécialisés (architecte, implémenteur, sécurité, qualité, UX) débattent,
challengent, et itèrent jusqu'au consensus. Tu supervises depuis Telegram.

## Comment ça marche

1. Tu déposes le brief du hackathon dans `inputs/`
2. Tu lances `./hackathon.sh`
3. Ultraplan crée un plan avec 4 agents Opus dans le cloud (30 min)
4. Tu review et approuves le plan dans le navigateur
5. 5 Agent Teams Opus se mettent au travail dans tmux
6. Ils recherchent la concurrence, codent, auditent, itèrent
7. Tu reçois les notifications et réponds aux questions sur Telegram
8. Quand le score qualité atteint 45/50 et la sécurité passe : ZIP prêt

## Prérequis

- Windows avec WSL2 (Ubuntu)
- Abonnement Claude Max 20x
- Compte GitHub avec `gh` CLI authentifié
- Bot Telegram (optionnel mais recommandé)

## Installation

```bash
# 1. Clone le pipeline
git clone <repo-url> hackathon-pipeline
cd hackathon-pipeline

# 2. Rendre exécutable
chmod +x hackathon.sh
```

Le setup (outils système, GitHub CLI, plugins, NOPASSWD sudo) est automatique
au premier lancement de `./hackathon.sh`.

## Configuration

```bash
# 1. Copier la config
cp hackathon.conf.example hackathon.conf

# 2. Éditer hackathon.conf
nano hackathon.conf
# Remplis : HACKATHON_NAME, HACKATHON_DEADLINE
# Optionnel : TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID
```

## Bot Telegram (recommandé)

1. Ouvre `@BotFather` sur Telegram
2. `/newbot` puis choisis un nom et username (doit finir par `bot`)
3. Copie le token retourné dans `hackathon.conf` (`TELEGRAM_BOT_TOKEN`)
4. Envoie un message au bot, puis récupère ton chat_id :
   ```bash
   curl -s "https://api.telegram.org/bot<TOKEN>/getUpdates" | jq '.result[0].message.chat.id'
   ```
5. Copie le chat_id dans `hackathon.conf` (`TELEGRAM_CHAT_ID`)

## Lancer un hackathon

```bash
# 1. Dépose les fichiers du hackathon
cp ~/Downloads/hackathon-brief.pdf inputs/
cp ~/Downloads/rules.md inputs/brief.md
cp ~/Downloads/judging-criteria.md inputs/criteria.md

# 2. Lance le pipeline
./hackathon.sh

# 3. Suis les instructions pour ultraplan
# 4. Monitore via Telegram
# 5. Le ZIP sera dans le répertoire parent du projet
```

## Options

```bash
./hackathon.sh                    # Pipeline complet (ultraplan + agents)
./hackathon.sh --skip-ultraplan   # Skip ultraplan (si plan déjà fait)
./hackathon.sh --attach           # Attach à la session tmux existante
```

## Structure

```
hackathon-pipeline/
├── hackathon.sh              # Point d'entrée (avec auto-setup intégré)
├── hackathon.conf.example    # Template de config
├── lib/
│   ├── telegram.sh           # Communication Telegram
│   └── utils.sh              # Logging, git, config, prérequis
├── agents/
│   ├── architecte.md         # Challenge les choix techniques
│   ├── implementeur.md       # Code production-quality
│   ├── securite.md           # Audit continu + PASS/FAIL
│   ├── qualite.md            # Évaluation /50 + READY/NOT READY
│   └── uiux-designer.md     # Design premium, anti-AI-slop
├── templates/
│   └── CLAUDE.md.template    # Instructions complètes du pipeline
└── inputs/                   # Fichiers du hackathon ici
```

## Comment ça fonctionne en détail

### Ultraplan (phase 1)
4 agents Opus tournent 30 min dans le cloud d'Anthropic.
3 explorers analysent en parallèle, 1 critic challenge.
Tu review le plan dans un navigateur avec commentaires inline.

### Agent Teams (phase 2+)
5 agents dans une session interactive tmux :
- **Lead** (toi dans le pipeline) : coordonne, synthétise
- **Architecte** : valide chaque décision technique
- **Implémenteur** : code, teste, commit
- **Sécurité** : audite chaque changement, vote PASS/FAIL
- **Qualité** : évalue /50, compare aux winners, vote READY/NOT READY

Les agents communiquent entre eux directement.
L'Implémenteur envoie un changement.
La Sécurité détecte une faille et le signale.
L'Implémenteur corrige. La Sécurité re-valide.
La boucle continue sans limite jusqu'au consensus.

### Terminaison
Le pipeline s'arrête UNIQUEMENT quand :
- Qualité vote READY (score ≥ 45/50)
- Sécurité vote PASS
- Documentation complète avec liens en ligne
- Setup.sh fonctionne
- Tests passent
- Archive ZIP créée

## Safeguards

Le pipeline configure automatiquement des protections dans `.claude/settings.json`
pour empêcher les agents de faire des dégâts :

**Commandes bloquées (deny rules)**
- `gh repo delete/archive/edit` — protection des repos GitHub
- `git push --force` / `--force-with-lease` — protection de l'historique
- `rm -rf /`, `rm -rf ~`, `rm -rf /*` — protection du système

**Commandes autorisées (allow rules)**
- `gh repo create/view`, `git push origin`, `git add/commit/log/diff/status/tag`
- `git remote add` — nécessaire pour le setup initial

**Hook PreToolUse (protection active)**
En plus des deny rules, un hook PreToolUse inspecte chaque commande Bash
avant exécution. Il lit le JSON d'entrée sur stdin, extrait la commande
avec `jq`, et vérifie les patterns dangereux avec `grep`. Si un pattern
matche, le hook retourne `{"decision": "block"}` et la commande est bloquée.
Les deny rules et le hook sont deux couches complémentaires : les deny rules
sont la première ligne, le hook est le filet de sécurité.

**Portée**
Ces safeguards ne s'appliquent qu'au projet du hackathon
(`.claude/settings.json` dans le répertoire du projet).
Vos autres repos et projets ne sont pas impactés.

## Troubleshooting

**La session tmux a disparu**
Le script de surveillance la relance automatiquement.
Pour vérifier : `tmux ls`

**Rate limit atteint**
Le pipeline ne crash pas. Claude attend et reprend.
Sur Max 20x, les limites sont rarement atteintes.
Active "extra usage" dans les settings Claude si nécessaire.

**Claude demande un mot de passe sudo**
Relance `./hackathon.sh` — auto_setup configure NOPASSWD automatiquement.

**Ultraplan échoue**
Assure-toi que le projet est un repo GitHub.
Ultraplan nécessite un repo pour cloner dans le cloud.

**Pas de notification Telegram**
Vérifie TELEGRAM_BOT_TOKEN et TELEGRAM_CHAT_ID dans hackathon.conf.
Teste : `curl -s "https://api.telegram.org/bot<TOKEN>/getMe"`
