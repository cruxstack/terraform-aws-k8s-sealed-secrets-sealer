# terraform-aws-k8s-sealed-secrets-sealer

Terraform module that deploys the control plane of
[k8s-sealed-secrets-sealer](https://github.com/cruxstack/k8s-sealed-secrets-sealer)
to AWS Lambda, behind an API Gateway HTTP API, with a DynamoDB table for each
env and an EventBridge Scheduler schedule for its ticks.

## What It Deploys

- **Lambda function** - The release's Lambda zip (`bootstrap` for
  `provided.al2023`, with the web UI built in), checked against the
  release's checksums
- **HTTP API** - One `$default` route and stage for the web UI, the user API
  and the agent API, throttled and logged, with an optional custom domain
- **DynamoDB tables** - One per env, with TTL, point-in-time recovery,
  deletion protection and a customer managed KMS key
- **SSM parameters** - Secrets as SecureStrings, each env's agent registry,
  and `APP_ENVS` when there are several envs
- **IAM roles** - The function's, with only the actions the app uses, and
  the schedule's, which may only invoke the function
- **Tick schedule** - Invokes the function every minute, so reseal schedules
  run

It does not deploy:

- **Agents** - Each cluster runs one, from the app's Helm chart
  (`oci://ghcr.io/cruxstack/charts/k8s-sealed-secrets-sealer-agent`)
- **The control plane in a container** - The app's control plane chart runs
  it on Kubernetes instead of Lambda
- **KMS transit and escrow keys** - They belong in each env's account, with
  its clusters. The module only names each env's transit key
- **Backups** - Add the tables to an AWS Backup plan (see
  [Tables and backups](#tables-and-backups))

## Requirements

| Name      | Version     |
| --------- | ----------- |
| terraform | `>= 1.7`    |
| aws       | `>= 6.72.0` |
| buildkit  | `>= 0.0.2`  |
| random    | `>= 3.9.1`  |

The module downloads the release with the
[cruxstack/buildkit](https://registry.terraform.io/providers/cruxstack/buildkit)
provider, which needs a BuildKit endpoint where Terraform runs (Docker
Desktop, OrbStack, or Colima, `BUILDKIT_HOST`, or an embedded rootless
`buildkitd` on Linux) and HTTPS to github.com. The tests need Terraform 1.11
or later.

## Usage

```hcl
module "sealer" {
  source = "github.com/cruxstack/terraform-aws-k8s-sealed-secrets-sealer?ref=v0.1.0"

  name = "sealer"

  envs = {
    prod = {
      kms_transit_key_arn = "arn:aws:kms:us-east-2:333333333333:key/mrk-0123456789abcdef0123456789abcdef"
      registry            = file("${path.module}/registries/prod.yaml")
    }
  }

  control_plane_config = {
    allowed_teams = ["prod-sealers"]
    admin_teams   = ["platform"]
  }

  github_app_config = {
    org           = "acme"
    app_id        = "123456"
    private_key   = var.github_app_private_key
    client_id     = "Iv23li0123456789abcd"
    client_secret = var.github_app_client_secret
  }

  domain_config = {
    enabled         = true
    domain_name     = "sealer.example.com"
    certificate_arn = "arn:aws:acm:us-east-2:111111111111:certificate/0123abcd-..."
    route53_zone_id = "Z0123456789ABCDEFGHIJ"
  }
}
```

Then:

1. Set the GitHub App's callback URL to the `oauth_callback_url` output (see
   [The GitHub App](#the-github-app)).
2. Allow the `lambda_role_arn` output on each env's transit key (see
   [Transit keys](#transit-keys)).
3. Install an agent in each cluster, with `controlPlane.url` set to the `url`
   output.

See [examples/complete](examples/complete) for two envs on one URL.

### One URL or One Deployment per Env

The app serves one env, or several on one URL. Each env keeps its own
registry, table, transit key and agents either way.

- **One URL.** List several envs in `envs`. People sign in once and switch
  envs in the UI, at `/<env>/...`. Agents name their env in each request.
  The module stores the envs as `APP_ENVS` in an SSM parameter, since
  Lambda's environment holds only 4 KB. Every env shares the function and
  its IAM role.
- **One deployment per env.** Use the module once per env, each with one env
  in `envs` and its own domain. The module then uses the app's single-env
  settings (`APP_ENV_NAME` and so on). Each env gets its own function and
  role, so whoever can deploy dev cannot touch prod. Choose this when prod
  must be isolated from everything else.

```hcl
module "sealer_dev" {
  source = "github.com/cruxstack/terraform-aws-k8s-sealed-secrets-sealer?ref=v0.1.0"

  name       = "sealer"
  attributes = ["dev"]

  envs = {
    dev = {
      kms_transit_key_arn = var.dev_transit_key_arn
      registry            = file("${path.module}/registries/dev.yaml")
    }
  }

  domain_config = {
    enabled         = true
    domain_name     = "sealer.dev.example.com"
    certificate_arn = var.dev_certificate_arn
  }

  github_app_config = var.github_app_config
}
```

Envs on one URL are listed in name order, and `/` opens the first one a
person may use. Going from one env to several moves the env's settings into
`APP_ENVS`; the app then derives each env's agent session key, so agents log
in again once. Agents must be v0.6.0 or later, with `env` set, before a
second env is added.

### The GitHub App

One GitHub App reads repositories, opens pull requests and signs people in.
Create it in the organization's settings, under Developer settings, GitHub
Apps:

- **Homepage URL:** the `url` output.
- **Callback URL:** the `oauth_callback_url` output,
  `https://<domain>/api/v1/auth/callback`.
- **Webhook:** off. The control plane receives no webhooks.
- **Repository permissions:** Contents (read and write), Metadata (read), and
  Pull requests (read and write).
- **Organization permissions:** Members (read), to check people's teams.

Generate a private key and a client secret, and install the app on the
organization, on the repositories people seal in. Give the module the App
ID, client ID, private key and client secret in `github_app_config`. The
installation is looked up on the org unless `installation_id` is set. For
GitHub Enterprise Server, set `url` and `api_url`.

### Transit Keys

Each env's transit key lives in the env's account, often as a multi-Region
key with a replica in the control plane's region. The control plane only
generates data keys with it, for the env's seals. Its policy needs this
statement for the `lambda_role_arn` output, beside the account's usual
statements and the agents' (see the app's
[deployment guide](https://github.com/cruxstack/k8s-sealed-secrets-sealer/blob/main/docs/deployment.md#1-keys-in-each-envs-account)):

```json
{
  "Sid": "ControlPlaneEncryptsForProd",
  "Effect": "Allow",
  "Principal": { "AWS": "arn:aws:iam::111111111111:role/sealer" },
  "Action": "kms:GenerateDataKey",
  "Resource": "*",
  "Condition": {
    "StringEquals": {
      "kms:EncryptionContext:env": "prod",
      "kms:EncryptionContext:purpose": "seal"
    }
  }
}
```

Put it on the primary key and on every replica: each has a policy of its
own. Apply the module first, since a key policy cannot name a role that
does not exist yet. The function's role already allows
`kms:GenerateDataKey` on each env's key, with the same conditions.

### Agent Registry

Each env's registry lists its agents and how each logs in. Give it as YAML
in `registry`, which the module stores in an SSM String parameter (advanced
tier over 4 KB, up to 8 KB), or as `registry_parameter_arn`, a parameter you
manage. The function reads it again about once a minute, so adding an agent
needs no deploy of the function.

```yaml
issuers: []
agents:
  - id: prod-use1-blue
    cluster: prod-use1-blue
    region: use1
    capabilities: [seal, keys, renewal, cleanup, reseal]
    identity:
      aws:
        roleArn: arn:aws:iam::333333333333:role/sealer-agent-prod-use1-blue
```

| Field                   | Holds                                                         |
| ----------------------- | ------------------------------------------------------------- |
| `agents[].id`           | The agent's ID, unique in the env                             |
| `agents[].cluster`      | The cluster's name                                            |
| `agents[].region`       | The cluster's region label, which documents' annotations name |
| `agents[].capabilities` | `seal`, `keys`, `renewal`, `cleanup`, `reseal`                |
| `agents[].identity.aws` | `roleArn`, and optionally `roleId`                            |
| `agents[].identity.k8s` | `issuer` (an issuer's `name`) and `subject`                   |
| `issuers[]`             | `name`, `url`, and `jwksURL` (or `jwksFile`, `caFile`)        |

A registry grows by about 200 bytes per agent, so a parameter holds about 40
agents. The app's
[registry format](https://github.com/cruxstack/k8s-sealed-secrets-sealer/blob/main/docs/deployment.md#3-a-registry-per-env)
has the details.

### Secrets

Each secret is an SSM SecureString parameter under
`ssm_config.parameter_prefix` (default `/<id>/`), encrypted with
`ssm_config.kms_key_arn` or `aws/ssm`. The function gets the parameter's ARN
and reads it at start, so no secret is in its configuration:

| Secret                      | From                                                  |
| --------------------------- | ----------------------------------------------------- |
| GitHub App private key      | `github_app_config.private_key` (PEM)                 |
| GitHub App client secret    | `github_app_config.client_secret`                     |
| Agent and user session keys | `session_keys_config`, or generated                   |
| Shared admin token          | `admin_token_config.token`, or generated when enabled |
| An env's own admin token    | `admin_token_config.env_tokens[<env>]`, or generated  |

To keep a secret out of Terraform, set it to the ARN of a parameter you
manage. The module passes the ARN as is and lets the function read it. A
parameter encrypted with another customer managed key also needs
`kms:Decrypt` on that key, which you can attach to the `lambda_role_name`
output.

Settings in SSM are read when an instance starts. So when a parameter the
module manages changes, the module changes `SEALER_CONFIG_REVISION` in the
function's environment, which replaces its instances. Registries are read
again while it runs.

### Admin API

The admin API gives monitoring an env's fleet without a GitHub sign-in. It
is off unless `admin_token_config.enabled` is set, or an env has a token of
its own in `env_tokens`. A token only reads, unless its env sets
`admin_token_key_changes`; then it also revokes, reinstates and deletes
keys. Give such an env its own token, so a token handed to monitoring cannot
change its keys. The `admin_token` and `env_admin_tokens` outputs hold the
tokens.

### Tables and Backups

Each env's table holds its escrowed sealing keys and its revocations, which
nothing else can rebuild. Keep it for good:

- Deletion protection is on. Turn off
  `dynamodb_config.deletion_protection_enabled` only to destroy an env on
  purpose.
- Point-in-time recovery is on.
- Back the tables up with AWS Backup, with copies in another region. They
  carry the module's tags, so a backup plan can select them by tag.

Tables are named `<id>-<env>`. To use an existing table, such as one restored
from a backup, set the env's `dynamodb_table.name`, and its `kms_key_arn` if
it uses a customer managed key. The app's
[restore guide](https://github.com/cruxstack/k8s-sealed-secrets-sealer/blob/main/docs/operations.md#restoring-the-table)
covers the rest.

### Ticks

Reseal schedules run on ticks. An EventBridge Scheduler schedule invokes the
function with `{"sealer": "tick"}` at `tick_config.schedule_expression`
(`rate(1 minute)` by default), and the module sets the app's tick interval to
match. Without it, reseal schedules never start.

### Timeouts and Concurrency

The function's timeout is 60 seconds by default, and at least 35: agents
hold command polls for up to 25 seconds, and ticks run until 10 seconds
before the timeout. API Gateway gives up on any request after 30 seconds.

Each agent holds one invocation most of the time. Reserve the function
concurrency for every agent plus people's requests with
`lambda_config.reserved_concurrent_executions`. Past about 50 agents, the
control plane costs less in a container.

### CloudFront in Front

API Gateway passes requests through as they are, headers included. A proxy
in front, such as CloudFront, must pass on cookies, query strings, and the
`Sec-Fetch-Site` or `X-Requested-With` header: without one of them, the app
refuses to list repositories and files. Cache nothing under `/api` or
`/agent`. Set `control_plane_config.public_url` to the proxy's URL.

## Upgrading

Set `app_version` to a newer release. The module downloads its zip, and the
function runs it on the next apply. Read the release notes of every version
you cross. Upgrade the control plane first, then the agents, within one
minor version. Keep each env's table across upgrades.

## Inputs

In addition to the variables documented below, this module includes several
other optional variables (e.g., `name`, `tags`, etc.) provided by the
`cloudposse/label/null` module. Please refer to its [documentation](https://registry.terraform.io/modules/cloudposse/label/null/latest)
for more details on these variables.

| Name                           | Description                                                                                                   | Type           | Default                                 | Required |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------- | -------------- | --------------------------------------- | -------- |
| `envs`                         | envs served, by name; see [below](#env-settings)                                                              | `map(object)`  | n/a                                     | yes      |
| `github_app_config`            | `org`, `app_id`, `private_key`, `client_id`, `client_secret`, `installation_id`, `url`, `api_url` (sensitive) | `object`       | n/a                                     | yes      |
| `app_version`                  | release tag of k8s-sealed-secrets-sealer to deploy                                                            | `string`       | `"v0.10.0"`                             | no       |
| `app_repo`                     | GitHub repository of the release, as `owner/name`                                                             | `string`       | `"cruxstack/k8s-sealed-secrets-sealer"` | no       |
| `app_force_rebuild_id`         | change to download the function's code again                                                                  | `string`       | `""`                                    | no       |
| `log_level`                    | `debug`, `info`, `warn`, or `error`                                                                           | `string`       | `"info"`                                | no       |
| `log_format`                   | `json` or `text`                                                                                              | `string`       | `"json"`                                | no       |
| `control_plane_config`         | shared settings; see [below](#shared-settings)                                                                | `object`       | `{}`                                    | no       |
| `session_keys_config`          | `agent_session_key`, `user_session_key`; generated when empty (sensitive)                                     | `object`       | `{}`                                    | no       |
| `admin_token_config`           | `enabled`, `token`, `env_tokens`; generated when empty (sensitive)                                            | `object`       | `{}`                                    | no       |
| `ssm_config`                   | `parameter_prefix` (default `/<id>/`), `kms_key_arn`                                                          | `object`       | `{}`                                    | no       |
| `ssm_parameter_arns`           | other parameter ARNs the function may read                                                                    | `list(string)` | `[]`                                    | no       |
| `dynamodb_config`              | `kms_key_arn` (default: a new key), `deletion_protection_enabled` (`true`)                                    | `object`       | `{}`                                    | no       |
| `lambda_config`                | `memory_size` (256), `timeout` (60, at least 35), `architecture` (`arm64`), `reserved_concurrent_executions`  | `object`       | `{}`                                    | no       |
| `lambda_log_retention_days`    | days to keep the function's and API's logs                                                                    | `number`       | `30`                                    | no       |
| `lambda_environment_variables` | more environment variables for the function; they override the module's                                       | `map(string)`  | `{}`                                    | no       |
| `vpc_config`                   | `subnet_ids`, `security_group_ids`                                                                            | `object`       | `null`                                  | no       |
| `api_gateway_config`           | `throttling_burst_limit` (100), `throttling_rate_limit` (50)                                                  | `object`       | `{}`                                    | no       |
| `domain_config`                | `enabled`, `domain_name`, `certificate_arn`, `route53_zone_id`                                                | `object`       | `{}`                                    | no       |
| `tick_config`                  | `enabled` (`true`), `schedule_expression` (`rate(1 minute)`, 1 to 10 minutes)                                 | `object`       | `{}`                                    | no       |

### Env Settings

Each entry of `envs` takes:

| Field                     | Holds                                                                      |
| ------------------------- | -------------------------------------------------------------------------- |
| `kms_transit_key_arn`     | the env's transit key ARN (required); each env needs its own               |
| `registry`                | the agent registry as YAML; or                                             |
| `registry_parameter_arn`  | the ARN of a parameter holding it                                          |
| `dynamodb_table`          | `name` and `kms_key_arn` of an existing table, instead of a new one        |
| `allowed_teams`           | team slugs that may use the env; replace the shared ones, even when empty  |
| `admin_teams`             | team slugs of the env's admins; replace the shared ones                    |
| `admin_token_key_changes` | the env's admin token may revoke, reinstate and delete keys                |
| `env_annotation`          | annotation key that places a document in an env                            |
| `region_annotation`       | annotation key that places a document in a region                          |
| `discovery_file_globs`    | globs of the files searched for SealedSecrets                              |
| `key_renew_period`        | how often a controller renews its key when no cluster does, such as `720h` |

Env names are DNS labels, and cannot be the UI's own paths (`api`,
`secrets`, `fleet`, and so on).

### Shared Settings

`control_plane_config` takes `allowed_teams` (empty: any org member),
`admin_teams` (empty: nobody), `user_session_ttl` (`15m` to `24h`, default
`8h`), `public_url`, `agent_audience` (default: the public URL),
`aws_sts_hosts`, and the defaults of `env_annotation`, `region_annotation`,
`discovery_file_globs` and `key_renew_period`. Unset ones are left to the
app's defaults.

## Outputs

| Name                        | Description                                                            |
| --------------------------- | ---------------------------------------------------------------------- |
| `url`                       | public URL, for people and the agents' `controlPlane.url`              |
| `agent_audience`            | audience the agents' `identity.audience` must equal                    |
| `oauth_callback_url`        | callback URL to set in the GitHub App                                  |
| `admin_token`               | shared admin token, when enabled (sensitive)                           |
| `env_admin_tokens`          | envs' own admin tokens, by env (sensitive)                             |
| `lambda_function_name`      | name of the Lambda function                                            |
| `lambda_function_arn`       | ARN of the Lambda function                                             |
| `lambda_role_arn`           | ARN of the function's role, for the transit key policies               |
| `lambda_role_name`          | name of the function's role                                            |
| `lambda_log_group_name`     | name of the function's log group                                       |
| `api_gateway_id`            | ID of the HTTP API                                                     |
| `api_gateway_endpoint`      | default endpoint of the HTTP API                                       |
| `api_gateway_domain_target` | `domain_name` and `hosted_zone_id` the custom domain's alias points to |
| `dynamodb_tables`           | each env's table `name` and `arn`, by env                              |
| `dynamodb_kms_key_arn`      | ARN of the key of the tables the module creates                        |
| `ssm_parameter_arns`        | ARNs of the module's parameters, by name under the prefix              |
| `scheduler_schedule_arn`    | ARN of the tick schedule                                               |

## Architecture

```
  people                        agents, one per cluster
     |                                  |
     | HTTPS                            | HTTPS, opened by the agent
     v                                  v
+----+----------------------------------+----+
|  API Gateway HTTP API, $default route      |
+---------------------+----------------------+
                      |
                      v              {"sealer": "tick"}
+---------------------+------+     +----------------------+
|  Lambda: control plane     | <---+  EventBridge         |
|  web UI, user and agent API|     |  Scheduler           |
+--+-----------+---------+---+     +----------------------+
   |           |         |
   v           v         v
DynamoDB      SSM      KMS transit key of each env
one table     secrets, (GenerateDataKey only,
per env       registries in the env's account)
```

## License

MIT Licensed. See [LICENSE](LICENSE) for full details.
