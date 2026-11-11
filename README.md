# terraform-aws-k8s-sealed-secrets-sealer

Terraform module that deploys the control plane of
[k8s-sealed-secrets-sealer](https://github.com/cruxstack/k8s-sealed-secrets-sealer)
to AWS Lambda, behind an API Gateway HTTP API, with a DynamoDB table per env
and an EventBridge Scheduler tick.

Agents, and the control plane in a container, are deployed with the app's
Helm charts. Each env's KMS transit and escrow keys belong in the env's own
account.

## Features

- **Release package** - Runs the release's Lambda zip, checked against its
  `checksums.txt`; nothing is built from source
- **One URL or one per env** - Serves several envs on one URL, or one env per
  deployment for isolation
- **A table per env** - TTL, point-in-time recovery, deletion protection, and
  a customer managed KMS key
- **Disaster recovery** - Global table replicas, and replicas of their key,
  in other regions
- **Secrets in SSM** - SecureString parameters, generated when not given, or
  your own parameters by ARN
- **Least privilege** - The function's role holds only the DynamoDB, KMS,
  SSM, and logs actions the app uses
- **Ticks** - An EventBridge Scheduler schedule runs reseal schedules
- **Custom domain** - Optional, with its Route 53 record

## Requirements

| Name      | Version     |
| --------- | ----------- |
| terraform | `>= 1.7`    |
| aws       | `>= 6.72.0` |
| buildkit  | `>= 0.0.2`  |
| random    | `>= 3.9.1`  |

The module fetches the release with the
[cruxstack/buildkit](https://registry.terraform.io/providers/cruxstack/buildkit)
provider, which needs a BuildKit endpoint where Terraform runs (Docker
Desktop, OrbStack, Colima, `BUILDKIT_HOST`, or an embedded rootless
`buildkitd` on Linux) and HTTPS to github.com. The tests need Terraform 1.11.

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
    admin_teams = ["platform"]
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
    certificate_arn = var.certificate_arn
    route53_zone_id = var.route53_zone_id
  }
}
```

Then set the GitHub App's callback URL to `oauth_callback_url`, allow
`lambda_role_arn` on each env's transit key, and install the agents with
`controlPlane.url` set to `url`. See [examples/complete](examples/complete)
for two envs on one URL.

### One URL or One Deployment per Env

Each env has its own registry, table, transit key, and agents either way.

- **One URL:** list several envs in `envs`. People sign in once and switch
  envs at `/<env>/...`. The envs go to the app as `APP_ENVS`, in an SSM
  parameter. Every env shares the function and its role.
- **One deployment per env:** use the module once per env, each with one env
  and its own domain. Whoever can deploy dev then cannot touch prod.

Going from one env to several makes agents log in again once. Agents must be
v0.6.0 or later, with `env` set, before a second env is added.

### GitHub App

One GitHub App reads repositories, opens pull requests, and signs people in.

- **Homepage URL:** the `url` output.
- **Callback URL:** the `oauth_callback_url` output,
  `https://<domain>/api/v1/auth/callback`.
- **Webhook:** off.
- **Repository permissions:** Contents (read and write), Metadata (read),
  Pull requests (read and write).
- **Organization permissions:** Members (read).

Install it on the organization, on the repositories people seal in.

### Transit Keys

Each env's transit key policy must allow the `lambda_role_arn` output, on the
primary key and on every replica. Apply the module first: a key policy cannot
name a role that does not exist yet.

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

The agents' statements are in the app's
[deployment guide](https://github.com/cruxstack/k8s-sealed-secrets-sealer/blob/main/docs/deployment.md#1-keys-in-each-envs-account).

### Agent Registry

Each env's registry lists its agents and how each logs in. The module stores
`registry` in an SSM parameter, or reads yours from `registry_parameter_arn`.
The function reads it again every minute, so adding an agent needs no deploy.

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

An agent logs in with `identity.aws` (`roleArn`) or `identity.k8s` (`issuer`
and `subject`, with the issuer under `issuers`). A parameter holds about 40
agents. See the app's
[registry format](https://github.com/cruxstack/k8s-sealed-secrets-sealer/blob/main/docs/deployment.md#3-a-registry-per-env).

### Secrets and Backups

The GitHub App's private key and client secret, the session keys, and the
admin tokens are SecureString parameters under `/<id>/`. The function gets
their ARNs, not their values. Set any of them to the ARN of your own
parameter to keep it out of Terraform. The admin API is off until
`admin_token_config` enables it.

Each env's table holds its escrowed sealing keys and revocations, which
nothing else can rebuild. Deletion protection and point-in-time recovery are
on. Add the tables to an AWS Backup plan; they carry the module's tags. To
use a restored table, set the env's `dynamodb_table`.

### Disaster Recovery

With `dynamodb_config.replica_regions = ["us-east-2"]`, each env table the
module creates becomes a global table with a replica there, encrypted with a
replica of the table key. Tables an env brings in `dynamodb_table` are not
replicated.

A failover also needs each env's transit and escrow keys to be multi-Region
keys with replicas in the DR region, each with its own key policy statements,
and agents there to name their region's replicas.

To fail over:

1. Deploy the module in the DR region under a distinct label, such as
   `environment = "ue2"`: IAM role names are global. Give each env its
   transit key's DR replica as `kms_transit_key_arn`, and a `dynamodb_table`
   with its table's `name` (see `dynamodb_tables`) and the DR region's table
   key (see `dynamodb_replica_kms_key_arns`) as `kms_key_arn`.
2. Allow that deployment's `lambda_role_arn` on each transit key replica.
3. Move the domain to it.
4. Keep the old clusters' registry entries, and give the new clusters' agents
   those identities with the `keys` capability. Each agent then restores the
   env's keys from escrow (see the app's
   [A rebuilt cluster](https://github.com/cruxstack/k8s-sealed-secrets-sealer/blob/main/docs/operations.md#a-rebuilt-cluster)
   and
   [Losing a region](https://github.com/cruxstack/k8s-sealed-secrets-sealer/blob/main/docs/operations.md#losing-a-region)).

Run one control plane at a time, and keep the old region's off when it comes
back. Global tables settle concurrent writes by last writer wins, and the
app's conditional writes and transactions hold only within one region. A
replica is not a backup: it copies deletes and bad writes too, so keep
point-in-time recovery, which the replicas also have.

### CloudFront in Front

A proxy in front must pass cookies and the `Sec-Fetch-Site` or
`X-Requested-With` header, and cache nothing under `/api` or `/agent`. Set
`control_plane_config.public_url` to its URL.

## Inputs

In addition to the variables documented below, this module includes several
other optional variables (e.g., `name`, `tags`, etc.) provided by the
`cloudposse/label/null` module. Please refer to its [documentation](https://registry.terraform.io/modules/cloudposse/label/null/latest)
for more details on these variables.

| Name                           | Description                                                                                                   | Type           | Default                                 | Required |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------- | -------------- | --------------------------------------- | -------- |
| `envs`                         | envs to serve, by name; see [below](#envs)                                                                    | `map(object)`  | n/a                                     | yes      |
| `github_app_config`            | `org`, `app_id`, `private_key`, `client_id`, `client_secret`, `installation_id`, `url`, `api_url` (sensitive) | `object`       | n/a                                     | yes      |
| `control_plane_config`         | settings every env shares; see [below](#shared-settings)                                                      | `object`       | `{}`                                    | no       |
| `dynamodb_config`              | `kms_key_arn` (default: a new key), `deletion_protection_enabled`, `replica_regions`, `replica_kms_key_arns`  | `object`       | `{}`                                    | no       |
| `session_keys_config`          | `agent_session_key`, `user_session_key`; generated when empty                                                 | `object`       | `{}`                                    | no       |
| `admin_token_config`           | `enabled`, `token`, `env_tokens`; generated when empty                                                        | `object`       | `{}`                                    | no       |
| `ssm_config`                   | `parameter_prefix` (default `/<id>/`), `kms_key_arn`                                                          | `object`       | `{}`                                    | no       |
| `ssm_parameter_arns`           | other parameter ARNs the function may read                                                                    | `list(string)` | `[]`                                    | no       |
| `app_version`                  | release to deploy                                                                                             | `string`       | `"v0.10.0"`                             | no       |
| `app_repo`                     | repository of the release, for forks                                                                          | `string`       | `"cruxstack/k8s-sealed-secrets-sealer"` | no       |
| `app_force_rebuild_id`         | change to download the release again                                                                          | `string`       | `""`                                    | no       |
| `log_level`                    | `debug`, `info`, `warn`, or `error`                                                                           | `string`       | `"info"`                                | no       |
| `log_format`                   | `json` or `text`                                                                                              | `string`       | `"json"`                                | no       |
| `lambda_config`                | `memory_size` (256), `timeout` (60, at least 35), `architecture` (`arm64`), `reserved_concurrent_executions`  | `object`       | `{}`                                    | no       |
| `lambda_log_retention_days`    | days to keep the function's and API's logs                                                                    | `number`       | `30`                                    | no       |
| `lambda_environment_variables` | more environment variables; they override the module's                                                        | `map(string)`  | `{}`                                    | no       |
| `vpc_config`                   | `subnet_ids`, `security_group_ids`                                                                            | `object`       | `null`                                  | no       |
| `api_gateway_config`           | `throttling_burst_limit` (100), `throttling_rate_limit` (50)                                                  | `object`       | `{}`                                    | no       |
| `domain_config`                | `enabled`, `domain_name`, `certificate_arn`, `route53_zone_id`                                                | `object`       | `{}`                                    | no       |
| `tick_config`                  | `enabled` (`true`), `schedule_expression` (`rate(1 minute)` to `rate(10 minutes)`)                            | `object`       | `{}`                                    | no       |

### Envs

| Field                     | Holds                                                               |
| ------------------------- | ------------------------------------------------------------------- |
| `kms_transit_key_arn`     | the env's transit key ARN (required); each env needs its own        |
| `registry`                | the agent registry as YAML; or                                      |
| `registry_parameter_arn`  | the ARN of a parameter holding it                                   |
| `dynamodb_table`          | `name` and `kms_key_arn` of an existing table to use                |
| `allowed_teams`           | team slugs that may use the env, replacing the shared ones          |
| `admin_teams`             | team slugs of the env's admins, replacing the shared ones           |
| `admin_token_key_changes` | lets the env's admin token revoke, reinstate, and delete keys       |
| `env_annotation`          | annotation key that places a document in an env                     |
| `region_annotation`       | annotation key that places a document in a region                   |
| `discovery_file_globs`    | globs of the files searched for SealedSecrets                       |
| `key_renew_period`        | how often a controller renews its key when no cluster does (`720h`) |

Env names are DNS labels other than the UI's own paths (`api`, `secrets`,
`fleet`, and so on). Teams given for an env replace the shared ones even when
empty.

### Shared Settings

`control_plane_config` takes `allowed_teams` (empty: any org member),
`admin_teams` (empty: nobody), `user_session_ttl` (default `8h`),
`public_url` (default: the domain's or the API's), `agent_audience` (default:
the public URL), `aws_sts_hosts`, and defaults for the env settings above.

## Outputs

| Name                            | Description                                               |
| ------------------------------- | --------------------------------------------------------- |
| `dynamodb_tables`               | each env's table: `name`, `arn`, and `replicas` by region |
| `dynamodb_kms_key_arn`          | ARN of the key of the tables the module creates           |
| `dynamodb_replica_kms_key_arns` | ARNs of the replicas' table keys, by region               |
| `ssm_parameter_arns`            | ARNs of the module's parameters, by name                  |
| `admin_token`                   | shared admin token (sensitive)                            |
| `env_admin_tokens`              | envs' own admin tokens (sensitive)                        |
| `lambda_function_name`          | name of the Lambda function                               |
| `lambda_function_arn`           | ARN of the Lambda function                                |
| `lambda_log_group_name`         | name of the function's log group                          |
| `lambda_role_arn`               | ARN of the function's role, for the transit key policies  |
| `lambda_role_name`              | name of the function's role                               |
| `api_gateway_id`                | ID of the HTTP API                                        |
| `api_gateway_endpoint`          | default endpoint of the HTTP API                          |
| `url`                           | public URL, for people and the agents                     |
| `agent_audience`                | audience the agents' `identity.audience` must equal       |
| `oauth_callback_url`            | callback URL for the GitHub App                           |
| `api_gateway_domain_target`     | alias target of the custom domain's DNS record            |
| `scheduler_schedule_arn`        | ARN of the tick schedule                                  |

Every output is null when the module is disabled.

## Architecture

```
  people                         agents, one per cluster
     |                                    |
     | HTTPS                              | HTTPS, opened by the agent
     v                                    v
+----+------------------------------------+----+
|  API Gateway HTTP API, $default route        |
+----------------------+-----------------------+
                       |
                       v               {"sealer": "tick"}
+----------------------+------+     +----------------------+
|  Lambda: control plane      | <---+  EventBridge         |
|  web UI, user and agent API |     |  Scheduler           |
+--+------------+---------+---+     +----------------------+
   |            |         |
   v            v         v
DynamoDB       SSM       KMS transit key of each env
one table      secrets,  (GenerateDataKey only,
per env        registries in the env's account)
```

## Upgrading

Set `app_version` to a newer release; the next apply deploys it. Read the
release notes of every version you cross, and upgrade the control plane
before the agents, within one minor version. Keep each env's table.

## License

MIT Licensed. See [LICENSE](LICENSE) for full details.
