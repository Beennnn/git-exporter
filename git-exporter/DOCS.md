# Configuration

```yaml
repository:
  url: <path to your repository>
  username: user
  password: pass
  pull_before_push: true
  commit_message: 'Home Assistant Git Exporter'
  branch_name: 'main'
export:
  lovelace: true
  addons: true
  esphome: true
  node_red: true
checks:
  enabled: true
  check_for_secrets: true
  check_for_ips: true
  mode: error
exclude:
  - '*.db'
  - '*.log'
  - __pycache__
  - deps/
  - known_devices.yaml
  - tts/
  - '*.db-shm'
  - '*.db-wal'
  - '*.gz'
secrets: []
allowed_secrets: []
dry_run: false
```

### `repository.url`

Any https url to your git repository. (For now _no_ SSH)

### `repository.email` (Optional)

The email address the commits author is using.

### `repository.username`

Your username for https authentication.

### `repository.password`

Your password or [__access token__](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens) for your repository.

### `repository.pull_before_push`

Should the repository be pulled first and commit the new state on top?

### `repository.commit_message`

The commit message for the next commit.

### `repository.branch_name`

The working branch for the repository.

### `repository.ssl_verification` (Optional, default: true)

Use this to disable the ssl verification. Can be used for self-signed certificates. __Use this only when you know what you are doing__


### `export.lovelace`

Enable / Disable the export for the lovelace config.

### `export.addons`

Enable / Disable the export for the supervisor addons config.

### `export.esphome`

Enable / Disable the export for the esphome config.

### `export.node_red`

Enable / Disable the export for the Node-RED flows.
Secure your credentials with [node-red-contrib-credentials](https://flows.nodered.org/node/node-red-contrib-credentials).


### `checks.enabled`

Master switch for the secret / IP scan. When `true`, the addon scans the
exported yaml/json/disabled files with `git-secrets` before committing.

Nine built-in prohibited patterns always run when `checks.enabled: true`,
regardless of the sub-toggles below. They flag any line matching one of:
`password:`, `token:`, `client_id:`, `api_key:`, `chat_id:`,
`allowed_chat_ids:`, `latitude:`, `longitude:`, `credential_secret:`.

Lines that include `!secret` (HA convention) are automatically allowed.

### `checks.check_for_secrets`

Adds the values from `/config/secrets.yaml` as additional prohibited
patterns, so any yaml file that hardcodes one of your real secret
values gets flagged. The sub-toggle name is a bit narrower than it
sounds: even with `checks.check_for_secrets: false`, the 9 built-in
`password:`/`token:`/... patterns above still run. Setting this to
`true` only ADDS more patterns from secrets.yaml — it does not by
itself enable or disable the whole secret scan.

### `checks.check_for_ips`

Add pattern for ip and mac addresses to the search.

### `checks.mode` (Optional, default: `error`)

Controls how the addon reacts when the scan finds a match.

* `error` (default) — log the matches and abort the run. Nothing gets
  committed or pushed. This is the existing behaviour.
* `warn` — log the matches with a warning and proceed with the commit
  and push anyway. Useful when you know the flagged content is safe
  (private repo, well-scoped audience, deferred cleanup) and you don't
  want the sync blocked while you migrate secrets to `!secret` refs.

Only affects the check step. If `checks.enabled: false`, this option
is ignored.


### `exclude`

The files / folders which should be excluded from the config export.

Following folders and files are excluded from the sync per default:

* `secrets.yaml` (secrets are cleared)
* `.cloud`
* `.storage`

### `secrets`

Additional secrets which will be checked for.


### `allowed_secrets`

Additional allowed secrets which will not make the secret check fail.


### `dry_run`

Only show the changes and don't commit or push.


## Known limitations

`check_for_secrets` Uses a git plugin that does pattern matching using regexes.
A limitation of this plugin is that using brackets (like `[`, `]`, `{`, `}` `(` and `)`) in secrets can result in unexpected behaviour and crashes.

If the addon fails during secrets checking with errors originating from grep (I.E. `grep: Unmatched [, [^, [:, [., or [=`),
change the passwords that contain brackets or set `check_for_secrets` to `false`.
