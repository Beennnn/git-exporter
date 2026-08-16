# Configuration

```yaml
repository:
  url: <path to your repository>
  username: user
  password: pass
  pull_before_push: true
  commit_message: 'Home Assistant Git Exporter'
  commit_message_prompt: ''
  commit_message_api_key: ''
  commit_message_model: 'claude-haiku-4-5-20251001'
  commit_message_timeout: 10
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

The commit message for the next commit. Also used as the fallback whenever AI
message generation is disabled or fails (see below).

### `repository.commit_message_prompt` (Optional)

Prompt sent to the LLM when AI commit messages are enabled. Leave empty to use a
sensible default (one-line French, conventional-commits style, ≤ 72 chars). The
staged diff is appended to this prompt automatically.

### `repository.commit_message_api_key` (Optional)

Anthropic API key. **This is the on/off switch**: when set (e.g. via
`!secret anthropic_api_key`), each commit message is generated from the actual
diff by the model. When empty (default), the static `commit_message` is used —
no API call is made. Any API failure or timeout silently falls back to the
static message, so a commit is never blocked.

### `repository.commit_message_model` (Optional)

Model id used for message generation. Default: `claude-haiku-4-5-20251001`
(cheapest; ~$1.80/month at a 15-minute export cadence).

### `repository.commit_message_timeout` (Optional)

Seconds to wait for the API before falling back to the static message.
Default: `10`.

### `repository.branch_name`

The working branch for the repository.

### `repository.skip_when_deploy_pending` (Optional, default: false)

Removes the race between this exporter (HA → git) and a companion git-deployer
(git → HA). When enabled, before snapshotting the exporter compares the remote
branch head to a "last deployed SHA" published by the deployer (see
`deployed_sha_entity`). If the remote is **ahead** of the deployed SHA — a merged
change hasn't reached `/config` yet — the exporter **skips this cycle** instead of
pushing the pre-deploy `/config` back and reverting it. Fail-safe when the guard
is off or the remote head is unknown: the exporter does **not** skip. For a
durably unreadable marker the behaviour is a deliberate trade-off, configurable
via `fail_closed_when_marker_unreadable`. Requires the deployer to publish the
marker reliably on every deploy; keep it `false` until that is in place. See the
consumer repo's `docs/design/deploy-snapshot-race.md`.

### `repository.deployed_sha_entity` (Optional)

The Home Assistant entity holding the last-deployed commit SHA, read via the
Supervisor's Core API. Default: `input_text.ha_deployed_sha`. Only used when
`skip_when_deploy_pending` is `true`.

**The read is retried** (6 attempts, 5 s apart) before the guard gives up and
falls back to snapshotting. This is not defensive padding: the marker *eclipses*
whenever the companion deployer's pass reloads the helpers — the API returns an
empty state, then no entity at all, for a few tens of seconds. That eclipse
happens precisely while a deploy is in flight, so a single failed read would drop
the guard exactly when it is needed and let the capture revert the just-merged
change. Retrying tells the two cases apart: an eclipse resolves within seconds, a
real outage (deployer dead, entity deleted, API down) outlives the window and is
handled by `fail_closed_when_marker_unreadable`.

### `repository.fail_closed_when_marker_unreadable` (Optional, default: false)

What to do when the marker is **still** unreadable after every retry — a real
outage, not the reload eclipse the retry already absorbs. The guard then cannot
tell whether a deploy is pending, and both answers lose something:

- `false` (default, historical) — snapshot anyway. Live capture is never frozen,
  but if a deploy *was* pending the snapshot reverts it, silently.
- `true` — abstain. No blind capture, so no silent revert; in exchange live
  capture stalls until the marker returns.

`true` is only safe because the abstention is **reported**: every cycle writes
its outcome to `status_entity`, so a stalled capture raises `MARKER_UNREADABLE`
instead of going unnoticed. Do not enable it without watching that entity — you
would be trading a silent revert for a silent freeze, which is worse.

### `repository.status_entity` (Optional)

Home Assistant `input_text` the exporter writes the outcome of each cycle to,
via the Supervisor's Core API. Default: `input_text.ha_exporter_last_result`.
Values: `OK`, `DEPLOY_PENDING`, `MERGE_PENDING`, `MARKER_UNREADABLE`. Publishing
is best-effort — a failure is logged and never aborts the export.

This is a **positive** report, not a heartbeat: supervision reads a written
result rather than inferring a failure from silence. Silence-based watchdogs on
this same pipeline were disabled twice for false positives, and their absence
then hid a real 7-day outage. `OK` is written last, after the push, so it means
the cycle finished rather than started.

A cycle that finds the configuration unchanged reports `OK` like any other: it
did its job, there was simply nothing to export. Until `beennnn.9` such a cycle
died on the empty `git commit` before publishing anything, which left the add-on
in `error` and this entity frozen on its previous value — so a quiet evening was
indistinguishable from a dead token.

### `repository.merged_branch` (Optional, default: empty = disabled)

Closes the other half of the race, for setups where reviewed changes land on a
branch (`main`) that is then fast-forwarded onto the deploy branch
(`branch_name`). `deployed_sha_entity` only proves `/config` is in sync with the
**deploy branch**; a change merged into `main` but not yet fast-forwarded is
invisible to that check, so the exporter would snapshot the pre-merge `/config`
and revert it. When set, the exporter also skips the cycle while
`merged_branch` carries commits the deploy branch lacks **and** those commits
change content under `deployed_subdir`.

The content test matters: the merge commit that absorbs a capture PR into `main`
has the same tree as the deploy branch, so it does not trigger a skip — otherwise
live captures would be frozen until the next fast-forward. The reverse case (the
deploy branch ahead of `merged_branch`, i.e. a capture waiting for its PR) is
normal and never skips. Fail-safe: unknown branch or unreadable diff → no skip.
Leave empty on single-branch setups. Only used when `skip_when_deploy_pending`
is `true`.

### `repository.deployed_subdir` (Optional, default: `config`)

The subtree the companion deployer actually writes back to `/config` (its
`deploy.subdir`). Only this subtree is compared by `merged_branch`: the
export-only trees (`lovelace/`, `esphome/`, `addons/`) never travel git → HA, so
a divergence there can't be resolved by a deploy and must not block the snapshot.

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

Enable / Disable the checks in the exported files.

### `checks.check_for_secrets`

Add your secret values to the check.

### `checks.check_for_ips`

Add pattern for ip and mac addresses to the search.


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
