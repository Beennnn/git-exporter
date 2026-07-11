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

bashio::log.info 'Start git export'

setup_git

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

    git commit -m "$commit_message"

    if [ ! "$pull_before_push" == 'true' ]; then
        git push --set-upstream origin "$branch" -f
    else
        git push origin
    fi
fi

bashio::log.info 'Exporter finished'
