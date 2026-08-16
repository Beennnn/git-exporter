#!/usr/bin/env bashio
set -e

# Enable Jemalloc for better memory handling
export LD_PRELOAD="/usr/local/lib/libjemalloc.so.2"

local_repository='/data/repository'
pull_before_push="$(bashio::config 'repository.pull_before_push')"

function setup_git {
    repository=$(bashio::config 'repository.url')
    username=$(bashio::config 'repository.username')
    password=$(bashio::config 'repository.password')
    commiter_mail=$(bashio::config 'repository.email')
    branch=$(bashio::config 'repository.branch_name')
    ssl_verify=$(bashio::config 'repository.ssl_verification')

    if [[ "$password" != "ghp_*" ]]  && [[ "$password" != "github_pat_*" ]]; then
        password=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${password}'))")
    fi

    if [ ! -d $local_repository ]; then
        bashio::log.info 'Create local repository'
        mkdir -p $local_repository
    fi
    cd $local_repository

    if [ "${ssl_verify:-true}" == 'false' ]; then
        bashio::log.info 'Disabling SSL verification for git repositories'
        git config --global http.sslVerify false
    fi

    fullurl="https://${username}:${password}@${repository##*https://}"

    if [ ! -d .git ]; then
        if [ "$pull_before_push" == 'true' ]; then
            bashio::log.info 'Clone existing repository'
            git clone "$fullurl" $local_repository
            git checkout "$branch"
        else
            bashio::log.info 'Initialize new repository'
            git init $local_repository
            git remote add origin "$fullurl"
        fi
        git config user.name "${username}"
        git config user.email "${commiter_mail:-git.exporter@home-assistant}"
    fi

    # Always refresh the origin URL from the current add-on options so a
    # rotated credential (e.g. a re-generated GitHub PAT) is picked up on
    # every run. Without this the credential is embedded only at the first
    # clone into the persistent /data/repository and never updated, so
    # rotating the token silently breaks fetch/push until /data is wiped
    # (add-on reinstall). See beennnn.3 changelog.
    if git remote get-url origin >/dev/null 2>&1; then
        git remote set-url origin "$fullurl"
    else
        git remote add origin "$fullurl"
    fi

    #Reset secrets if existing
    git config --unset-all 'secrets.allowed' || true
    git config --unset-all 'secrets.patterns' || true
    git config --unset-all 'secrets.providers' || true

    if [ "$pull_before_push" == 'true' ]; then
        bashio::log.info 'Pull latest'
        git fetch
        # Ensure the local branch actually IS $branch. Without this, a persistent
        # /data clone stays on whatever branch it was first cloned with, so
        # changing repository.branch_name in the options never takes effect (the
        # push at the end targets the old branch). checkout -B re-points the local
        # branch to origin/$branch and switches to it, so branch_name changes work
        # without clearing /data.
        git checkout -B "$branch" "origin/$branch"
        git reset --hard "origin/$branch"
    fi

    git clean -f -d
}

function check_secrets {
    bashio::log.info 'Add secrets pattern'

    # Allow !secret lines
    git secrets --add -a '!secret'

    # Set prohibited patterns
    git secrets --add "password:\s?[\'\"]?\w+[\'\"]?\n?"
    git secrets --add "token:\s?[\'\"]?\w+[\'\"]?\n?"
    git secrets --add "client_id:\s?[\'\"]?\w+[\'\"]?\n?"
    git secrets --add "api_key:\s?[\'\"]?\w+[\'\"]?\n?"
    git secrets --add "chat_id:\s?[\'\"]?\w+[\'\"]?\n?"
    git secrets --add "allowed_chat_ids:\s?[\'\"]?\w+[\'\"]?\n?"
    git secrets --add "latitude:\s?[\'\"]?\w+[\'\"]?\n?"
    git secrets --add "longitude:\s?[\'\"]?\w+[\'\"]?\n?"
    git secrets --add "credential_secret:\s?[\'\"]?\w+[\'\"]?\n?"

    if [ "$(bashio::config 'check.check_for_secrets')" == 'true' ]; then
        # Extract leaf values from /config/secrets.yaml and add them as
        # git-secrets patterns. See utils/extract_secret_values.py for the
        # filtering rules (regex-escape, skip booleans/numbers/short values).
        # The previous inline `sed` version was buggy in three ways:
        #   1. `s/\s//g` deleted the letter 's' from every value.
        #   2. Values were unescaped, so `.` matched any char.
        #   3. No length/type filter → `port: 8123` matched the default HA port
        #      everywhere and `true`/`false` matched every boolean.
        git secrets --add-provider -- /utils/extract_secret_values.py /config/secrets.yaml
    fi

    if [ "$(bashio::config 'check.check_for_ips')" == 'true' ]; then
        git secrets --add '([0-9]{1,3}\.){3}[0-9]{1,3}'
        git secrets --add '([0-9A-Fa-f]{2}[:-]){5}([0-9A-Fa-f]{2})'

        # Allow dummy / general ips and mac
        git secrets --add -a --literal 'AA:BB:CC:DD:EE:FF'
        git secrets --add -a --literal '123.456.789.123'
        git secrets --add -a --literal '0.0.0.0'
    fi

    bashio::log.info 'Add secrets from secrets.yaml'
    prohibited_patterns=$(git config --get-all secrets.patterns)
    bashio::log.info "Prohibited patterns:\n${prohibited_patterns//\\n/\\\\n}"

    readarray -t <<<"$(bashio::config 'secrets' | grep -v '^$')"
    # shellcheck disable=SC2128
    if [ -n "$MAPFILE" ] && [ ${#MAPFILE[@]} -gt 0 ]; then
        bashio::log.info 'Add custom secrets'
        for secret in "${MAPFILE[@]}"; do
            git secrets --add "$secret"
        done
    fi

    readarray -t <<<"$(bashio::config 'allowed_secrets' | grep -v '^$')"
    # shellcheck disable=SC2128
    if [ -n "$MAPFILE" ] && [ ${#MAPFILE[@]} -gt 0 ]; then
        bashio::log.info 'Add custom allowed secrets'
        for allowed_secret in "${MAPFILE[@]}"; do
            git secrets --add -a "$allowed_secret"
        done
    fi

    bashio::log.info 'Checking for secrets'
    # shellcheck disable=SC2046
    git secrets --scan $(find $local_repository -name '*.yaml' -o -name '*.yml' -o -name '*.json' -o -name '*.disabled') \
    || (bashio::log.error 'Found secrets in files!!! Fix them to be able to commit! See https://www.home-assistant.io/docs/configuration/secrets/ for more information!' && exit 1)
}

function export_ha_config {
    bashio::log.info 'Get Home Assistant config'
    excludes=$(bashio::config 'exclude')
    excludes=("secrets.yaml" ".storage" ".cloud" "esphome/" ".uuid" "node-red/" "${excludes[@]}")

    # Cleanup existing esphome folder from config
    [ -d "${local_repository}/config/esphome" ] && rm -r "${local_repository}/config/esphome"
    # shellcheck disable=SC2068
    exclude_args=$(printf -- '--exclude=%s ' ${excludes[@]})
    # shellcheck disable=SC2086
    rsync -archive --compress --delete --checksum --prune-empty-dirs -q --include='.gitignore' $exclude_args /config ${local_repository}
    sed 's/:.*$/: ""/g' /config/secrets.yaml > ${local_repository}/config/secrets.yaml
    chmod 644 -R ${local_repository}/config
}

function export_lovelace {
    bashio::log.info 'Get Lovelace config yaml'
    [ ! -d "${local_repository}/lovelace" ] && mkdir "${local_repository}/lovelace"
    mkdir -p '/tmp/lovelace'
    find /config/.storage -name "lovelace*" -printf '%f\n' | xargs -I % cp /config/.storage/% /tmp/lovelace/%.json
    /utils/jsonToYaml.py '/tmp/lovelace/' 'data'
    rsync -archive --compress --delete --checksum --prune-empty-dirs -q --include='*.yaml' --exclude='*' /tmp/lovelace/ "${local_repository}/lovelace"
    chmod 644 -R "${local_repository}/lovelace"
}

function export_esphome {
    bashio::log.info 'Get ESPHome configs'
    rsync -archive --compress --delete --checksum --prune-empty-dirs -q \
         --exclude='.esphome*' --include='*/' --include='.gitignore' --include='*.yaml' --include='*.disabled' --exclude='secrets.yaml' --exclude='*' \
        /config/esphome ${local_repository}
    [ -f /config/esphome/secrets.yaml ] && sed 's/:.*$/: ""/g' /config/esphome/secrets.yaml > ${local_repository}/esphome/secrets.yaml
    chmod 644 -R ${local_repository}/esphome
}

function export_addons {
    [ -d ${local_repository}/addons ] || mkdir -p ${local_repository}/addons
    installed_addons=$(bashio::addons.installed)
    mkdir '/tmp/addons/'
    for addon in $installed_addons; do
        if [ "$(bashio::addons.installed "${addon}")" == 'true' ]; then
            bashio::log.info "Get ${addon} configs"
            bashio::addon.options "$addon" >  /tmp/tmp.json
            /utils/jsonToYaml.py /tmp/tmp.json
            mv /tmp/tmp.yaml "/tmp/addons/${addon}.yaml"
        fi
    done
    bashio::log.info "Get addon repositories"
    bashio::api.supervisor GET "/store/repositories" false \
      | jq '. | map(select(.source != null and .source != "core" and .source != "local")) | map({(.name): {source,maintainer,slug}}) | add' > /tmp/tmp.json
    /utils/jsonToYaml.py /tmp/tmp.json
    mv /tmp/tmp.yaml "/tmp/addons/repositories.yaml"
    rsync -archive --compress --delete --checksum --prune-empty-dirs -q /tmp/addons/ ${local_repository}/addons
    chmod 644 -R ${local_repository}/addons
}

function export_node-red {
    bashio::log.info 'Get Node-RED flows'
    rsync -archive --compress --delete --checksum --prune-empty-dirs -q \
          --exclude='flows_cred.json' --exclude='*.backup' --include='flows.json' --include='settings.js' --exclude='*' \
        /config/node-red/ ${local_repository}/node-red
    chmod 644 -R ${local_repository}/node-red
}

# Generate a one-line commit message from the staged diff via the Anthropic API.
# Opt-in: only invoked when repository.commit_message_api_key is set. Prints the
# message to stdout, or nothing on ANY failure so the caller keeps the static
# repository.commit_message fallback. Never blocks or delays a commit beyond the
# configured timeout. See docs/design/ai-commit-messages.md (consumer config repo).
function generate_ai_commit_message {
    local api_key="$1"
    local prompt model timeout_s diff payload response ai_msg

    prompt="$(bashio::config 'repository.commit_message_prompt')"
    model="$(bashio::config 'repository.commit_message_model')"
    timeout_s="$(bashio::config 'repository.commit_message_timeout')"

    # Sane defaults when the options are left empty (bashio returns 'null' for unset optionals).
    if [ -z "$prompt" ] || [ "$prompt" == 'null' ]; then
        prompt="Rédige un message de commit Français d'une ligne (max 72 caractères, style conventional commits). Résume le diff ci-dessous. Pas d'introduction, juste la ligne."
    fi
    if [ -z "$model" ] || [ "$model" == 'null' ]; then
        model='claude-haiku-4-5-20251001'
    fi
    if [ -z "$timeout_s" ] || [ "$timeout_s" == 'null' ]; then
        timeout_s=10
    fi

    # Bound the diff: keeps the prompt cheap AND caps the prompt-injection surface
    # from arbitrary config-file content (design §"Failure mode considerations").
    diff="$( { git diff --cached --stat | head -50; echo; git diff --cached | head -300; } 2>/dev/null )" || true
    if [ -z "$diff" ]; then
        return 0
    fi

    payload="$(jq -n --arg model "$model" --arg prompt "$prompt" --arg diff "$diff" '{
        model: $model,
        max_tokens: 200,
        messages: [{role: "user", content: ($prompt + "\n\nDiff:\n" + $diff)}]
    }')"

    # -m timeout → falls back to static on any network hiccup; never hangs a commit.
    response="$(curl -sS -m "$timeout_s" -X POST https://api.anthropic.com/v1/messages \
        -H "x-api-key: ${api_key}" \
        -H 'anthropic-version: 2023-06-01' \
        -H 'content-type: application/json' \
        -d "$payload" 2>/dev/null || true)"

    # '// empty' → empty string on malformed JSON or an API error object.
    ai_msg="$(printf '%s' "$response" | jq -r '.content[0].text // empty' 2>/dev/null || true)"
    # Defensive: keep only the first non-blank line even if the model returns prose.
    ai_msg="$(printf '%s\n' "$ai_msg" | sed '/^[[:space:]]*$/d' | head -1)"

    printf '%s' "$ai_msg"
}

# Angle mort du garde ci-dessous : il ne voit que la branche de déploiement
# (origin/$branch). Une modification déjà fusionnée sur la branche de revue
# (typiquement `main`) mais pas encore fast-forwardée sur la branche de
# déploiement est INVISIBLE — origin/$branch == deployed_sha, le garde laisse
# passer, et le snapshot repousse le /config d'avant-fusion : la modification
# fusionnée est annulée. Vécu le 2026-08-15 (PR #216 `unique_id` sur les capteurs
# REST, annulée par une capture 10 min plus tard).
#
# On ferme donc la chaîne complète  merged_branch → branch → /config  :
#   merge_is_pending   couvre  merged_branch en avance sur branch  (ce chaînon)
#   deploy_is_pending  couvre  branch en avance sur /config        (deployed_sha)
#
# Deux conditions cumulatives, pour ne PAS geler le Workflow B (capture live) :
#   1. merged_branch n'est pas un ancêtre de branch — elle porte des commits que
#      la branche de déploiement n'a pas. (Le cas inverse, branch en avance, est
#      normal : c'est une capture live en attente de PR. On ne saute pas.)
#   2. le contenu déployable diffère réellement. Sans ce test, le merge commit
#      qui absorbe une PR de capture dans merged_branch (même arbre, historique
#      différent) ferait sauter la garde jusqu'au prochain fast-forward, et la
#      capture live serait gelée pendant des heures.
# Opt-in via repository.merged_branch (vide = désactivé). FAIL-SAFE partout :
# branche inconnue ou diff illisible → on NE saute PAS.
function merge_is_pending {
    local merged_branch merged head diff_rc subdir

    [ "$(bashio::config 'repository.skip_when_deploy_pending')" == 'true' ] || return 1

    merged_branch="$(bashio::config 'repository.merged_branch')"
    case "$merged_branch" in
        ''|null) return 1 ;;
    esac
    # Même branche des deux côtés (topologie mono-branche) : rien à comparer.
    [ "$merged_branch" != "$branch" ] || return 1

    merged="$(git -C "$local_repository" rev-parse --verify --quiet "origin/${merged_branch}" 2>/dev/null || true)"
    head="$(git -C "$local_repository" rev-parse --verify --quiet "origin/${branch}" 2>/dev/null || true)"
    if [ -z "$merged" ] || [ -z "$head" ]; then
        bashio::log.warning "Anti-course: origin/${merged_branch} ou origin/${branch} introuvable — snapshot autorisé (fail-safe)"
        return 1
    fi

    # 1. déjà contenue dans la branche de déploiement → rien de fusionné ne manque.
    if git -C "$local_repository" merge-base --is-ancestor "$merged" "$head" 2>/dev/null; then
        return 1
    fi

    # 2. différence de contenu SOUS LE SOUS-DOSSIER DÉPLOYÉ uniquement. Les arbres
    # export-only (lovelace/, esphome/, addons/) ne repartent jamais vers HA : une
    # divergence là ne peut pas être résolue par un déploiement, la prendre en
    # compte gèlerait la capture indéfiniment.
    subdir="$(bashio::config 'repository.deployed_subdir')"
    case "$subdir" in
        ''|null) subdir='config' ;;
    esac
    diff_rc=0
    git -C "$local_repository" diff --quiet "$head" "$merged" -- "$subdir" >/dev/null 2>&1 || diff_rc=$?
    # 0 = arbres identiques (merge commit sans contenu neuf) ; 1 = vraie différence ;
    # >1 = erreur git → fail-safe, on laisse passer.
    [ "$diff_rc" -eq 1 ] || return 1

    bashio::log.info "Anti-course: fusion non déployée (${merged_branch} ${merged:0:8} en avance sur ${branch} ${head:0:8}) — snapshot sauté"
    guard_status='MERGE_PENDING'
    return 0
}

# Issue du cycle, publiée dans une entité HA par publish_status (voir plus bas).
# Renseignée par les gardes ; 'OK' si aucune n'a rien à signaler.
guard_status='OK'

# publish_status ÉTAT — publie l'issue du cycle dans repository.status_entity.
#
# Pourquoi un compte-rendu POSITIF plutôt qu'une surveillance du silence : deux
# watchdogs successifs côté consommateur ont déduit la panne d'une ABSENCE de signal
# (âge de `ha_deployed_sha.last_updated`, puis un heartbeat époch). Les deux ont produit
# assez de faux positifs pour être désactivés — et leur désactivation a laissé passer
# une panne réelle de 7 jours (deployer en CONFLICT, 2026-08-08 → 08-15, aucune alerte).
# Un état écrit à chaque passe se lit sans inférence : pas de fenêtre à calibrer, pas de
# faux positif quand il ne se passe simplement rien. Même raisonnement que le capteur
# `sensor.deploiement_ha_dernier_resultat` côté HA.
#
# C'est ce compte-rendu qui rend le fail-closed tenable (cf. deploy_is_pending) : un
# snapshot sauté cesse d'être silencieux, donc un gel de la capture est signalé au lieu
# d'être découvert des jours plus tard.
#
# Best-effort : un échec de publication n'interrompt jamais l'export.
function publish_status {
    local entity payload
    entity="$(bashio::config 'repository.status_entity')"
    case "$entity" in
        ''|null) entity='input_text.ha_exporter_last_result' ;;
    esac

    payload="$(jq -n --arg e "$entity" --arg v "$1" '{entity_id:$e, value:$v}')"
    # shellcheck disable=SC2154  # SUPERVISOR_TOKEN is injected by the Supervisor at runtime
    if curl -sSL -m 10 -X POST \
        -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
        -H 'Content-Type: application/json' \
        -d "$payload" \
        "http://supervisor/core/api/services/input_text/set_value" >/dev/null 2>&1; then
        bashio::log.info "Compte-rendu publié : ${1} (${entity})"
    else
        bashio::log.warning "Compte-rendu non publié dans ${entity} (entité absente ?) — export poursuivi"
    fi
}

# Skip the snapshot when a deploy is pending — supprime la course exporter/deployer.
# git-deployer publie le SHA appliqué à /config (dans une entité HA input_text) après
# CHAQUE déploiement réussi. Si origin/$branch est EN AVANCE sur ce SHA, c'est qu'une
# PR mergée n'a pas encore atteint /config : snapshoter maintenant re-pousserait le
# /config d'avant-déploiement et annulerait le changement. On saute alors ce cycle ;
# le deployer rattrape, et le cycle suivant snapshote normalement.
# Opt-in via repository.skip_when_deploy_pending. FAIL-SAFE quand la garde est OFF ou que
# le HEAD distant est inconnu : on NE saute PAS. Pour le marqueur durablement illisible,
# le comportement est configurable depuis 1.17.1-beennnn.8 — voir le bloc d'arbitrage plus
# bas et docs/design/deploy-snapshot-race.md (repo consommateur ha-vallesvilles-family).
function deploy_is_pending {
    local enabled entity head deployed
    enabled="$(bashio::config 'repository.skip_when_deploy_pending')"
    [ "$enabled" == 'true' ] || return 1

    head="$(git -C "$local_repository" rev-parse --verify --quiet "origin/${branch}" 2>/dev/null || true)"
    if [ -z "$head" ]; then
        bashio::log.warning 'Anti-course: HEAD distant inconnu — snapshot autorisé (fail-safe)'
        return 1
    fi

    entity="$(bashio::config 'repository.deployed_sha_entity')"
    if [ -z "$entity" ] || [ "$entity" == 'null' ]; then
        entity='input_text.ha_deployed_sha'
    fi

    # Le marqueur s'ÉCLIPSE le temps que la passe du deployer recharge les helpers
    # (`reload_all`) : l'API renvoie d'abord un état vide, puis l'entité carrément absente,
    # pendant quelques dizaines de secondes. Sans réessai, la garde retombe en fail-safe
    # (« illisible → je capture ») PILE dans la fenêtre où un déploiement est en cours — et
    # la capture reverte la PR qu'on vient de merger. Vécu le 2026-08-16 : un redémarrage du
    # deployer a suffi à faire annuler la PR #226 par la capture suivante.
    #
    # On réessaie donc avant de conclure : une éclipse de rechargement se résorbe en
    # quelques secondes, une vraie panne (deployer mort, entité supprimée, API HS) persiste
    # au-delà de la fenêtre. Le fail-safe est CONSERVÉ pour ce second cas — c'est le choix
    # explicite du design (ne jamais casser le Workflow B en silence) — mais il ne se
    # déclenche plus sur une simple éclipse. Surchargeables pour les tests.
    local attempts="${DEPLOYED_SHA_READ_ATTEMPTS:-6}"
    local delay="${DEPLOYED_SHA_READ_DELAY:-5}"
    local attempt=0

    deployed=''
    while [ "$attempt" -lt "$attempts" ]; do
        # shellcheck disable=SC2154  # SUPERVISOR_TOKEN is injected by the Supervisor at runtime
        deployed="$(curl -sSL -m 10 -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
            "http://supervisor/core/api/states/${entity}" 2>/dev/null \
            | jq -r '.state // empty' 2>/dev/null || true)"

        case "$deployed" in
            ''|null|unknown|unavailable) ;;
            *) break ;;
        esac

        attempt=$((attempt + 1))
        if [ "$attempt" -lt "$attempts" ]; then
            bashio::log.info "Anti-course: ${entity} illisible (${attempt}/${attempts}) — nouvel essai dans ${delay}s"
            sleep "$delay"
        fi
    done

    # Panne DURABLE du marqueur : l'éclipse a survécu à tous les réessais. Ce n'est plus
    # un rechargement de helpers, c'est un vrai trou (deployer mort, entité supprimée ou
    # renommée, Core injoignable). On ne sait donc pas si un déploiement est en attente.
    #
    # Arbitrage tranché le 2026-08-16 (voir docs/design/deploy-snapshot-race.md § Constraints) :
    # le comportement dépend de repository.fail_closed_when_marker_unreadable.
    #   false (défaut, historique) — on capture quand même. Workflow B n'est jamais gelé,
    #     mais si un déploiement était en attente, la capture le reverte en silence.
    #   true  — on s'abstient. Plus aucun revert silencieux possible ; en contrepartie la
    #     capture live s'arrête tant que le marqueur ne revient pas. Ce qui rend ce choix
    #     tenable, c'est que l'abstention n'est PAS silencieuse : guard_status remonte
    #     MARKER_UNREADABLE, publié par publish_status et surveillé côté HA. On échange un
    #     revert silencieux contre un gel ANNONCÉ — pas contre un gel silencieux.
    # Le compte-rendu est émis dans les DEUX cas : même en fail-safe, un marqueur durablement
    # illisible est une anomalie qui mérite d'être vue.
    case "$deployed" in
        ''|null|unknown|unavailable)
            guard_status='MARKER_UNREADABLE'
            if [ "$(bashio::config 'repository.fail_closed_when_marker_unreadable')" == 'true' ]; then
                bashio::log.warning "Anti-course: ${entity} illisible après ${attempts} essais — snapshot SAUTÉ (fail-closed)"
                return 0
            fi
            bashio::log.warning "Anti-course: ${entity} illisible après ${attempts} essais — snapshot autorisé (fail-safe)"
            return 1 ;;
    esac

    if [ "$head" != "$deployed" ]; then
        bashio::log.info "Anti-course: déploiement en attente (${deployed:0:8} → ${head:0:8}) — snapshot sauté"
        guard_status='DEPLOY_PENDING'
        return 0
    fi
    return 1
}

bashio::log.info 'Start git export'

setup_git

if merge_is_pending || deploy_is_pending; then
    publish_status "$guard_status"
    bashio::log.info "Exporter finished (snapshot sauté: ${guard_status})"
    exit 0
fi

export_ha_config

if [ "$(bashio::config 'export.lovelace')" == 'true' ]; then
    export_lovelace
fi

if [ "$(bashio::config 'export.esphome')" == 'true' ] && [ -d '/config/esphome' ]; then
    export_esphome
fi

if [ "$(bashio::config 'export.addons')" == 'true' ]; then
    export_addons
fi

if [ "$(bashio::config 'export.node_red')" == 'true' ] && [ -d '/config/node-red' ]; then
    export_node-red
fi

if [ "$(bashio::config 'check.enabled')" == 'true' ]; then
    check_secrets
fi


if [ "$(bashio::config 'dry_run')" == 'true' ]; then
    git status
else
    bashio::log.info 'Commit changes and push to remote'
    git add .

    commit_message="$(bashio::config 'repository.commit_message')"

    # Optionally replace the static message with an AI-generated one describing the
    # actual diff. Opt-in via repository.commit_message_api_key; any failure silently
    # keeps the static fallback above (see generate_ai_commit_message).
    ai_api_key="$(bashio::config 'repository.commit_message_api_key')"
    if [ -n "$ai_api_key" ] && [ "$ai_api_key" != 'null' ] && ! git diff --cached --quiet; then
        bashio::log.info 'Generating AI commit message from staged diff'
        ai_commit_message="$(generate_ai_commit_message "$ai_api_key")"
        if [ -n "$ai_commit_message" ]; then
            commit_message="$ai_commit_message"
            bashio::log.info "AI commit message: ${commit_message}"
        else
            bashio::log.warning 'AI commit message unavailable — using static fallback'
        fi
    fi

    # `git commit` sort en code NON NUL quand il n'y a rien à commiter — ce n'est pas une
    # erreur, c'est le cas NOMINAL de toute passe où la config n'a pas bougé. Combiné au
    # `set -e` de la ligne 2, ça tuait le script ICI : pas de push, pas de publish_status,
    # pas de « Exporter finished », et l'add-on finissait en état `error`.
    #
    # Le vrai dégât n'est pas l'état affiché mais la perte du compte-rendu : la conception
    # de beennnn.8 (voir publish_status) repose sur un état écrit à CHAQUE passe, justement
    # pour ne plus déduire la panne d'un silence. Une soirée sans changement de config
    # laissait donc l'entité de statut figée sur sa valeur précédente — le seul signal de
    # santé que le consommateur surveille — tout en teintant l'add-on en rouge. Résultat :
    # « rien à faire » devenait indiscernable d'un jeton mort ou d'un dépôt injoignable.
    if git diff --cached --quiet; then
        bashio::log.info 'Nothing to commit — config unchanged since last export'
    else
        git commit -m "$commit_message"
    fi

    # Le push reste INCONDITIONNEL (hors dépôt encore vierge, où il n'y a pas de ref à
    # pousser). Sur une branche déjà à jour c'est un no-op, mais si une passe précédente a
    # commité SANS réussir à pousser (jeton expiré, DNS, dépôt injoignable — cf. le fix
    # beennnn.3), le commit resté en local repart au cycle suivant au lieu d'attendre le
    # prochain changement de config pour être découvert.
    if git rev-parse --verify --quiet HEAD >/dev/null; then
        if [ ! "$pull_before_push" == 'true' ]; then
            git push --set-upstream origin "$branch" -f
        else
            git push origin HEAD:"$branch"
        fi
    else
        bashio::log.warning 'Dépôt local sans aucun commit — rien à pousser'
    fi
fi

# Publié en TOUT DERNIER, une fois le push passé : « OK » doit vouloir dire que le cycle
# est allé au bout, pas qu'il a démarré. Le cas guard_status=MARKER_UNREADABLE arrive
# jusqu'ici quand le fail-safe a laissé passer la capture — l'anomalie remonte alors même
# si le snapshot a réussi, car c'est la seule trace d'une capture faite à l'aveugle.
publish_status "$guard_status"

bashio::log.info 'Exporter finished'
