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
- **GitHub App setup** - The control plane creates its own GitHub App from a
  setup page, or uses one you created by hand
- **A table per env** - TTL, point-in-time recovery, deletion protection, and
  a customer managed KMS key
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

  # the control plane creates its GitHub App from its setup page
  github_app_config = {
    org = "acme"
  }

  domain_config = {
    enabled         = true
    domain_name     = "sealer.example.com"
    certificate_arn = var.certificate_arn
    route53_zone_id = var.route53_zone_id
  }
}
```

Then have an owner of the org open `/setup` at `url` to create the GitHub
App, allow `lambda_role_arn` on each env's transit key, and install the
agents with `controlPlane.url` set to `url`. See
[examples/complete](examples/complete) for two envs on one URL, with an App
created by hand.

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
Give only `org` in `github_app_config`, and the control plane creates it from
its setup page:

1. Apply the module. Until the App exists, every page redirects to `/setup`
   and nobody can sign in; agents check in as usual.
2. An owner of the org opens `/setup` and creates the App on GitHub, which
   lets them rename it.
3. The control plane checks that the org owns the App, writes its ID,
   private key, client ID and secret to an SSM SecureString parameter, and
   sends the owner on to install it on the repositories people seal in.

The parameter is `<parameter_prefix>github-app`, `/<id>/github-app` by
default, or your own in `parameter_arn`, in the function's account; the
`github_app_parameter_arn` output names it. The function may read and write
only that parameter, which is under the account's `aws/ssm` key whatever
`ssm_config.kms_key_arn` is. It is written once, and Terraform does not
manage it, so it outlives a destroy. To replace the App, delete it on GitHub
and the parameter in SSM, and set it up again.

To create the App by hand instead, give `app_id`, `private_key`,
`client_id` and `client_secret`, the key and secret as values or parameter
ARNs:

- **Homepage URL:** the `url` output.
- **Callback URL:** the `oauth_callback_url` output,
  `https://<domain>/api/v1/auth/callback`.
- **Webhook:** off.
- **Repository permissions:** Contents (read and write), Metadata (read),
  Pull requests (read and write).
- **Organization permissions:** Members (read).

Install it on the organization, on the repositories people seal in.

### Transit Keys

A transit key may be single-Region or multi-Region, in any region; the
control plane calls it in the region its ARN names. A multi-Region key with a
replica in each region the control plane may run in keeps working when one
region is lost: set `kms_transit_key_arn` to the replica in the module's
region. A replica can only be made while its primary's region is up.

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

To allow a control plane that does not exist yet, such as one rebuilt in
another region, name its account and match its role's ARN instead. Here each
region's deployment is labelled by `environment`, so the roles are
`use1-sealer` and `use2-sealer`:

```json
{
  "Sid": "ControlPlanesEncryptForProd",
  "Effect": "Allow",
  "Principal": { "AWS": "arn:aws:iam::111111111111:root" },
  "Action": "kms:GenerateDataKey",
  "Resource": "*",
  "Condition": {
    "ArnLike": { "aws:PrincipalArn": "arn:aws:iam::111111111111:role/*-sealer" },
    "StringEquals": {
      "kms:EncryptionContext:env": "prod",
      "kms:EncryptionContext:purpose": "seal"
    }
  }
}
```

Whoever can create a role matching the pattern in that account can then call
the key as the control plane does, so guard `iam:CreateRole` there.

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

The session keys, the admin tokens, and a GitHub App's private key and
client secret given as values are SecureString parameters under `/<id>/`.
The function gets their ARNs, not their values. Set any of them to the ARN
of your own parameter to keep it out of Terraform. The admin API is off
until `admin_token_config` enables it.

Each env's table holds its escrowed sealing keys and revocations, which
nothing else can rebuild. Deletion protection and point-in-time recovery are
on. Add the tables to an AWS Backup plan with copies in another region; they
carry the module's tags. To use a restored table, set the env's
`dynamodb_table` to it and its KMS key, which must be in the module's region.

### Region Failover

The control plane can be rebuilt in another region, such as `us-east-2` when
`us-east-1` is down. Prepare these while both regions are up:

- **Keys:** clusters rebuilt there get the env's sealing keys only by
  decrypting escrow, so each env's escrow key must still be usable: a replica
  there, or a single-Region key in a region that stays up. A single-Region
  escrow key in the lost region leaves them without keys until it is back.
  The transit key can be either, or a new key made during the failover,
  since what it protects lasts only minutes. See [Transit Keys](#transit-keys)
  and the app's
  [deployment guide](https://github.com/cruxstack/k8s-sealed-secrets-sealer/blob/main/docs/deployment.md#1-keys-in-each-envs-account).
- **Tables:** the AWS Backup plan copies them to that region. Copies across
  regions need DynamoDB's advanced backup features turned on.
- **Domain:** an ACM certificate for the domain in that region.
- **Parameters:** copies there of any secret or registry given as a parameter
  ARN, and a key there for `ssm_config.kms_key_arn` if you set it. Copy the
  GitHub App's parameter too, and name the copy in `parameter_arn`;
  otherwise the setup page asks for a new App.

Then, in that region:

1. Restore each env's table from its copy, with a KMS key in that region.
2. Apply the module with its own label, such as `environment = "use2"`: IAM
   role names are global, and the old deployment's roles still exist. Set
   each env's `kms_transit_key_arn` to a transit key that is up, such as its
   replica there, and `dynamodb_table` to the restored table and its key.
   Keep `domain_name`, with the new certificate, and leave `route53_zone_id`
   empty, since the old deployment's record still exists. Point that record
   at the `api_gateway_domain_target` output.
3. Allow the new `lambda_role_arn` on each transit key it uses, unless a
   pattern there already matches it.
4. Finish each restore as the app's
   [runbook](https://github.com/cruxstack/k8s-sealed-secrets-sealer/blob/main/docs/operations.md#restoring-the-table)
   says: TTL, point-in-time recovery, the backup plan, and the revocations
   made since the backup.
5. Install the agents in the new clusters, each listed in its env's
   registry, with `kms.transitKeyId` and `kms.escrowKeyId` set to keys that
   are up, such as the replicas there. Each restores the env's keys from
   escrow.

With the same domain, the agents' `controlPlane.url` and audience and the
GitHub App's callback URL stay as they were. Generated session keys and admin
tokens are new, so people and agents sign in again.

### CloudFront in Front

A proxy in front must pass cookies and the `Sec-Fetch-Site` or
`X-Requested-With` header, and cache nothing under `/api` or `/agent`. Set
`control_plane_config.public_url` to its URL.

## Inputs

In addition to the variables documented below, this module includes several
other optional variables (e.g., `name`, `tags`, etc.) provided by the
`cloudposse/label/null` module. Please refer to its [documentation](https://registry.terraform.io/modules/cloudposse/label/null/latest)
for more details on these variables.

| Name                           | Description                                                                                                  | Type           | Default                                 | Required |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------ | -------------- | --------------------------------------- | -------- |
| `envs`                         | envs to serve, by name; see [below](#envs)                                                                   | `map(object)`  | n/a                                     | yes      |
| `github_app_config`            | `org`, and the App's credentials or none; see [GitHub App](#github-app) (sensitive)                          | `object`       | n/a                                     | yes      |
| `control_plane_config`         | settings every env shares; see [below](#shared-settings)                                                     | `object`       | `{}`                                    | no       |
| `dynamodb_config`              | `kms_key_arn` (default: a new key), `deletion_protection_enabled`                                            | `object`       | `{}`                                    | no       |
| `session_keys_config`          | `agent_session_key`, `user_session_key`; generated when empty                                                | `object`       | `{}`                                    | no       |
| `admin_token_config`           | `enabled`, `token`, `env_tokens`; generated when empty                                                       | `object`       | `{}`                                    | no       |
| `ssm_config`                   | `parameter_prefix` (default `/<id>/`), `kms_key_arn`                                                         | `object`       | `{}`                                    | no       |
| `ssm_parameter_arns`           | other parameter ARNs the function may read                                                                   | `list(string)` | `[]`                                    | no       |
| `app_version`                  | release to deploy                                                                                            | `string`       | `"v0.11.0"`                             | no       |
| `app_repo`                     | repository of the release, for forks                                                                         | `string`       | `"cruxstack/k8s-sealed-secrets-sealer"` | no       |
| `app_force_rebuild_id`         | change to download the release again                                                                         | `string`       | `""`                                    | no       |
| `log_level`                    | `debug`, `info`, `warn`, or `error`                                                                          | `string`       | `"info"`                                | no       |
| `log_format`                   | `json` or `text`                                                                                             | `string`       | `"json"`                                | no       |
| `lambda_config`                | `memory_size` (256), `timeout` (60, at least 35), `architecture` (`arm64`), `reserved_concurrent_executions` | `object`       | `{}`                                    | no       |
| `lambda_log_retention_days`    | days to keep the function's and API's logs                                                                   | `number`       | `30`                                    | no       |
| `lambda_environment_variables` | more environment variables; they override the module's                                                       | `map(string)`  | `{}`                                    | no       |
| `vpc_config`                   | `subnet_ids`, `security_group_ids`                                                                           | `object`       | `null`                                  | no       |
| `api_gateway_config`           | `throttling_burst_limit` (100), `throttling_rate_limit` (50)                                                 | `object`       | `{}`                                    | no       |
| `domain_config`                | `enabled`, `domain_name`, `certificate_arn`, `route53_zone_id`                                               | `object`       | `{}`                                    | no       |
| `tick_config`                  | `enabled` (`true`), `schedule_expression` (`rate(1 minute)` to `rate(10 minutes)`)                           | `object`       | `{}`                                    | no       |

### Envs

| Field                     | Holds                                                                                 |
| ------------------------- | ------------------------------------------------------------------------------------- |
| `kms_transit_key_arn`     | the env's own transit key ARN (required); the replica in this region, if multi-Region |
| `registry`                | the agent registry as YAML; or                                                        |
| `registry_parameter_arn`  | the ARN of a parameter holding it                                                     |
| `dynamodb_table`          | `name` and `kms_key_arn` of an existing table in this region                          |
| `allowed_teams`           | team slugs that may use the env, replacing the shared ones                            |
| `admin_teams`             | team slugs of the env's admins, replacing the shared ones                             |
| `admin_token_key_changes` | lets the env's admin token revoke, reinstate, and delete keys                         |
| `env_annotation`          | annotation key that places a document in an env                                       |
| `region_annotation`       | annotation key that places a document in a region                                     |
| `discovery_file_globs`    | globs of the files searched for SealedSecrets                                         |
| `key_renew_period`        | how often a controller renews its key when no cluster does (`720h`)                   |

Env names are DNS labels other than the UI's own paths (`api`, `secrets`,
`fleet`, and so on). Teams given for an env replace the shared ones even when
empty.

### Shared Settings

`control_plane_config` takes `allowed_teams` (empty: any org member),
`admin_teams` (empty: nobody), `user_session_ttl` (default `8h`),
`public_url` (default: the domain's or the API's), `agent_audience` (default:
the public URL), `aws_sts_hosts`, and defaults for the env settings above.

## Outputs

| Name                        | Description                                              |
| --------------------------- | -------------------------------------------------------- |
| `dynamodb_tables`           | each env's table name and ARN                            |
| `dynamodb_kms_key_arn`      | ARN of the key of the tables the module creates          |
| `ssm_parameter_arns`        | ARNs of the module's parameters, by name                 |
| `github_app_parameter_arn`  | parameter the setup page writes the App to               |
| `admin_token`               | shared admin token (sensitive)                           |
| `env_admin_tokens`          | envs' own admin tokens (sensitive)                       |
| `lambda_function_name`      | name of the Lambda function                              |
| `lambda_function_arn`       | ARN of the Lambda function                               |
| `lambda_log_group_name`     | name of the function's log group                         |
| `lambda_role_arn`           | ARN of the function's role, for the transit key policies |
| `lambda_role_name`          | name of the function's role                              |
| `api_gateway_id`            | ID of the HTTP API                                       |
| `api_gateway_endpoint`      | default endpoint of the HTTP API                         |
| `url`                       | public URL, for people and the agents                    |
| `agent_audience`            | audience the agents' `identity.audience` must equal      |
| `oauth_callback_url`        | callback URL for the GitHub App                          |
| `api_gateway_domain_target` | alias target of the custom domain's DNS record           |
| `scheduler_schedule_arn`    | ARN of the tick schedule                                 |

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
