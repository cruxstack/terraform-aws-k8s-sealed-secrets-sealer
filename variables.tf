# ===================================================================== app ===

variable "app_version" {
  description = "Release of k8s-sealed-secrets-sealer to deploy, a tag such as `v0.10.0`. The function runs the release's Lambda zip, which must match the release's `checksums.txt`."
  type        = string
  default     = "v0.10.0"

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?$", var.app_version))
    error_message = "app_version must be a release tag, such as v0.10.0."
  }
}

variable "app_repo" {
  description = "GitHub repository whose release is deployed, as `owner/name`. Change it only for a fork that publishes the same release files."
  type        = string
  default     = "cruxstack/k8s-sealed-secrets-sealer"

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$", var.app_repo))
    error_message = "app_repo must be a GitHub repository as owner/name."
  }
}

variable "app_force_rebuild_id" {
  description = "Change this value to download the function's code again."
  type        = string
  default     = ""
}

variable "log_level" {
  description = "Log level of the function: `debug`, `info`, `warn`, or `error`."
  type        = string
  default     = "info"

  validation {
    condition     = contains(["debug", "info", "warn", "error"], var.log_level)
    error_message = "log_level must be one of: debug, info, warn, error."
  }
}

variable "log_format" {
  description = "Log format of the function: `json` or `text`."
  type        = string
  default     = "json"

  validation {
    condition     = contains(["json", "text"], var.log_format)
    error_message = "log_format must be json or text."
  }
}

# ==================================================================== envs ===

variable "envs" {
  description = <<-EOT
    The envs the control plane serves, by name. One env is configured with
    the app's single-env settings (`APP_ENV_NAME`); several are served on one
    URL through `APP_ENVS`, in name order. Each env has:

    - `kms_transit_key_arn`: the env's transit key, in the env's account (often
      a multi-Region replica in this region). Each env needs its own.
    - `registry`: the env's agent registry, as YAML, which the module stores in
      an SSM parameter; or `registry_parameter_arn`, an existing parameter that
      holds it. Exactly one of the two.
    - `dynamodb_table`: the `name` of an existing table to use instead of
      creating one, and its `kms_key_arn` when it uses a customer managed key.
    - `allowed_teams`, `admin_teams`: replace the shared teams of
      `control_plane_config` for this env, even when empty.
    - `admin_token_key_changes`: lets the env's admin token, its own or the
      shared one, revoke, reinstate and delete keys.
    - `env_annotation`, `region_annotation`, `discovery_file_globs`,
      `key_renew_period`: replace the shared settings for this env.
  EOT
  type = map(object({
    kms_transit_key_arn    = string
    registry               = optional(string, "")
    registry_parameter_arn = optional(string, "")
    dynamodb_table = optional(object({
      name        = string
      kms_key_arn = optional(string, "")
    }))
    allowed_teams           = optional(list(string))
    admin_teams             = optional(list(string))
    admin_token_key_changes = optional(bool, false)
    env_annotation          = optional(string, "")
    region_annotation       = optional(string, "")
    discovery_file_globs    = optional(list(string), [])
    key_renew_period        = optional(string, "")
  }))

  validation {
    condition     = length(var.envs) > 0
    error_message = "envs must name at least one env."
  }

  validation {
    condition     = alltrue([for name in keys(var.envs) : can(regex("^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$", name))])
    error_message = "Each env name must be a DNS label: lowercase letters, digits and hyphens, at most 63 characters."
  }

  validation {
    condition = alltrue([
      for name in keys(var.envs) :
      !contains(["agent", "api", "assets", "auth", "fleet", "healthz", "login", "readyz", "repos", "secrets", "static"], name)
    ])
    error_message = "An env name cannot be one of the web UI's own paths: agent, api, assets, auth, fleet, healthz, login, readyz, repos, secrets, static."
  }

  validation {
    condition     = alltrue([for env in var.envs : can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$", env.kms_transit_key_arn))])
    error_message = "Each env's kms_transit_key_arn must be a KMS key ARN, not a key ID or alias."
  }

  # the replicas of a multi-Region key are one key in every region
  validation {
    condition = length(distinct([
      for env in var.envs : replace(env.kms_transit_key_arn, "/^(arn:[^:]+:kms:)[^:]+(:[0-9]+:key/mrk-)/", "$${1}*$${2}")
    ])) == length(var.envs)
    error_message = "Each env needs its own transit key; replicas of one multi-Region key count as one key."
  }

  validation {
    condition     = alltrue([for env in var.envs : (env.registry == "") != (env.registry_parameter_arn == "")])
    error_message = "Each env needs exactly one of registry and registry_parameter_arn."
  }

  validation {
    condition = alltrue([
      for env in var.envs :
      env.registry_parameter_arn == "" || can(regex("^arn:aws(-[a-z]+)*:ssm:[a-z0-9-]+:[0-9]{12}:parameter/[A-Za-z0-9_./-]+$", env.registry_parameter_arn))
    ])
    error_message = "Each env's registry_parameter_arn must be an SSM parameter ARN."
  }

  validation {
    condition     = alltrue([for env in var.envs : env.registry == "" || can(yamldecode(env.registry).agents[0])])
    error_message = "Each env's registry must be YAML that lists at least one agent, as the app requires."
  }

  validation {
    condition     = alltrue([for env in var.envs : length(env.registry) <= 8192])
    error_message = "Each env's registry must be at most 8192 characters, which an advanced SSM parameter holds; give a larger one as registry_parameter_arn."
  }

  validation {
    condition = alltrue([
      for env in var.envs :
      env.dynamodb_table == null ? true : can(regex("^[A-Za-z0-9_.-]{3,255}$", env.dynamodb_table.name))
    ])
    error_message = "Each env's dynamodb_table.name must be a DynamoDB table name."
  }

  validation {
    condition = alltrue([
      for env in var.envs :
      env.dynamodb_table == null ? true : (env.dynamodb_table.kms_key_arn == "" || can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$", env.dynamodb_table.kms_key_arn)))
    ])
    error_message = "Each env's dynamodb_table.kms_key_arn must be a KMS key ARN."
  }

  validation {
    condition = alltrue([
      for env in var.envs :
      alltrue([
        for key in [env.env_annotation, env.region_annotation] :
        key == "" || can(regex("^([a-z0-9]([-a-z0-9]*[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*/)?[A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?$", key))
      ])
    ])
    error_message = "Each env's env_annotation and region_annotation must be an annotation key, such as example.com/env."
  }

  validation {
    condition     = alltrue([for env in var.envs : env.key_renew_period == "" || can(regex("^([0-9]+(\\.[0-9]+)?(ns|us|µs|ms|s|m|h))+$", env.key_renew_period))])
    error_message = "Each env's key_renew_period must be a duration, such as 720h."
  }
}

# =========================================================== control plane ===

variable "control_plane_config" {
  description = <<-EOT
    Settings every env shares, each optional:

    - `allowed_teams`: GitHub team slugs whose members may use an env; empty
      lets any org member in. `admin_teams`: team slugs of the env's admins;
      empty makes nobody an admin. An env's own teams replace these.
    - `user_session_ttl`: how long a sign-in lasts, `15m` to `24h` (app
      default `8h`).
    - `public_url`: the URL people and agents use, when something in front of
      the API, such as CloudFront, serves it at another URL. By default it is
      the custom domain's, or else the API's.
    - `agent_audience`: the audience agents sign their logins for, when it is
      not the public URL.
    - `aws_sts_hosts`: the STS hosts agents' logins may be forwarded to,
      replacing the app's list of AWS's public hosts.
    - `env_annotation`, `region_annotation`, `discovery_file_globs`,
      `key_renew_period`: the app's defaults unless set.
  EOT
  type = object({
    allowed_teams        = optional(list(string), [])
    admin_teams          = optional(list(string), [])
    user_session_ttl     = optional(string, "")
    public_url           = optional(string, "")
    agent_audience       = optional(string, "")
    aws_sts_hosts        = optional(list(string), [])
    env_annotation       = optional(string, "")
    region_annotation    = optional(string, "")
    discovery_file_globs = optional(list(string), [])
    key_renew_period     = optional(string, "")
  })
  default = {}

  validation {
    condition = alltrue([
      for d in [var.control_plane_config.user_session_ttl, var.control_plane_config.key_renew_period] :
      d == "" || can(regex("^([0-9]+(\\.[0-9]+)?(ns|us|µs|ms|s|m|h))+$", d))
    ])
    error_message = "control_plane_config.user_session_ttl and key_renew_period must be durations, such as 8h."
  }

  validation {
    condition     = var.control_plane_config.public_url == "" || can(regex("^https://[^/?#@]+/?$", var.control_plane_config.public_url))
    error_message = "control_plane_config.public_url must be an https URL without a path, such as https://sealer.example.com."
  }

  validation {
    condition     = var.control_plane_config.agent_audience == "" || can(regex("^https?://[^/?#]+", var.control_plane_config.agent_audience))
    error_message = "control_plane_config.agent_audience must be a URL, such as https://sealer.example.com."
  }

  validation {
    condition     = alltrue([for h in var.control_plane_config.aws_sts_hosts : can(regex("^[^/?#@ ]+$", h))])
    error_message = "control_plane_config.aws_sts_hosts must be host names, optionally with a port."
  }

  validation {
    condition = alltrue([
      for key in [var.control_plane_config.env_annotation, var.control_plane_config.region_annotation] :
      key == "" || can(regex("^([a-z0-9]([-a-z0-9]*[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*/)?[A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?$", key))
    ])
    error_message = "control_plane_config.env_annotation and region_annotation must be annotation keys, such as example.com/env."
  }
}

# ================================================================== github ===

variable "github_app_config" {
  description = "The GitHub App that reads repositories, opens pull requests and signs people in with its OAuth client. `private_key` (PEM) and `client_secret` are values or SSM parameter ARNs. `installation_id` is looked up on the org when empty. `url` and `api_url` are a GitHub Enterprise Server's web and API URLs."
  sensitive   = true
  type = object({
    org             = string
    app_id          = string
    private_key     = string
    installation_id = optional(string, "")
    client_id       = string
    client_secret   = string
    url             = optional(string, "")
    api_url         = optional(string, "")
  })

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9-]{0,38}$", var.github_app_config.org))
    error_message = "github_app_config.org must be a GitHub organization name."
  }

  validation {
    condition     = can(regex("^[0-9]+$", var.github_app_config.app_id)) && can(regex("^[0-9]*$", var.github_app_config.installation_id))
    error_message = "github_app_config.app_id and installation_id must be numbers."
  }

  validation {
    condition     = strcontains(var.github_app_config.private_key, "PRIVATE KEY-----") || can(regex("^arn:aws(-[a-z]+)*:ssm:[a-z0-9-]+:[0-9]{12}:parameter/[A-Za-z0-9_./-]+$", var.github_app_config.private_key))
    error_message = "github_app_config.private_key must be a PEM private key or an SSM parameter ARN."
  }

  validation {
    condition     = var.github_app_config.client_id != "" && var.github_app_config.client_secret != ""
    error_message = "github_app_config.client_id and client_secret are required."
  }

  validation {
    condition = alltrue([
      for u in [var.github_app_config.url, var.github_app_config.api_url] : u == "" || can(regex("^https://[^/?#]+", u))
    ])
    error_message = "github_app_config.url and api_url must be https URLs, such as https://github.example.com and https://github.example.com/api/v3."
  }
}

# ================================================================= secrets ===

variable "session_keys_config" {
  description = "Keys that sign agents' and people's sessions: values of at least 32 bytes, or SSM parameter ARNs. Each one left empty is generated. Changing one ends the sessions it signed."
  sensitive   = true
  type = object({
    agent_session_key = optional(string, "")
    user_session_key  = optional(string, "")
  })
  default = {}

  validation {
    condition = alltrue([
      for k in [var.session_keys_config.agent_session_key, var.session_keys_config.user_session_key] :
      k == "" || length(k) >= 32 || can(regex("^arn:aws(-[a-z]+)*:ssm:[a-z0-9-]+:[0-9]{12}:parameter/[A-Za-z0-9_./-]+$", k))
    ])
    error_message = "Session keys must be at least 32 characters, or SSM parameter ARNs."
  }
}

variable "admin_token_config" {
  description = "Admin API tokens. With `enabled`, a shared token (`token`, or generated when empty) reads the fleet of every env without its own. `env_tokens` gives envs, by name, a token of their own (a value, or empty to generate one). Tokens are values of at least 32 bytes or SSM parameter ARNs. A token changes keys only in envs with `admin_token_key_changes`."
  sensitive   = true
  type = object({
    enabled    = optional(bool, false)
    token      = optional(string, "")
    env_tokens = optional(map(string), {})
  })
  default = {}

  validation {
    condition = alltrue([
      for t in concat([var.admin_token_config.token], values(var.admin_token_config.env_tokens)) :
      t == "" || length(t) >= 32 || can(regex("^arn:aws(-[a-z]+)*:ssm:[a-z0-9-]+:[0-9]{12}:parameter/[A-Za-z0-9_./-]+$", t))
    ])
    error_message = "Admin tokens must be at least 32 characters, or SSM parameter ARNs."
  }
}

variable "ssm_config" {
  description = "Where the module keeps its SSM parameters: under `parameter_prefix` (default `/<id>/`), with secrets encrypted by `kms_key_arn` instead of `aws/ssm` when it is set."
  type = object({
    parameter_prefix = optional(string, "")
    kms_key_arn      = optional(string, "")
  })
  default = {}

  validation {
    condition     = var.ssm_config.parameter_prefix == "" || can(regex("^/([A-Za-z0-9_.-]+/)+$", var.ssm_config.parameter_prefix))
    error_message = "ssm_config.parameter_prefix must start and end with a slash, such as /sealer/."
  }

  validation {
    condition     = var.ssm_config.kms_key_arn == "" || can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$", var.ssm_config.kms_key_arn))
    error_message = "ssm_config.kms_key_arn must be a KMS key ARN."
  }
}

variable "ssm_parameter_arns" {
  description = "Other SSM parameter ARNs the function may read, for settings you set to a parameter ARN through `lambda_environment_variables`."
  type        = list(string)
  default     = []
}

# ================================================================ dynamodb ===

variable "dynamodb_config" {
  description = "The envs' DynamoDB tables. The module creates a customer managed KMS key for the tables it creates unless `kms_key_arn` is given. `deletion_protection_enabled` guards the tables, which hold each env's escrowed sealing keys: losing one can lose keys for good, so turn it off only to destroy an env on purpose."
  type = object({
    kms_key_arn                 = optional(string, "")
    deletion_protection_enabled = optional(bool, true)
  })
  default = {}

  validation {
    condition     = var.dynamodb_config.kms_key_arn == "" || can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$", var.dynamodb_config.kms_key_arn))
    error_message = "dynamodb_config.kms_key_arn must be a KMS key ARN."
  }
}

# ================================================================== lambda ===

variable "lambda_config" {
  description = "Configuration of the Lambda function. Agents hold command polls for up to 25 seconds, and ticks run until 10 seconds before the timeout, so the timeout must be at least 35 seconds."
  type = object({
    memory_size                    = optional(number, 256)
    timeout                        = optional(number, 60)
    architecture                   = optional(string, "arm64")
    reserved_concurrent_executions = optional(number, -1)
  })
  default = {}

  validation {
    condition     = var.lambda_config.memory_size >= 128 && var.lambda_config.memory_size <= 10240
    error_message = "Lambda memory_size must be between 128 and 10240 MB."
  }

  validation {
    condition     = var.lambda_config.timeout >= 35 && var.lambda_config.timeout <= 900
    error_message = "Lambda timeout must be between 35 and 900 seconds."
  }

  validation {
    condition     = contains(["arm64", "x86_64"], var.lambda_config.architecture)
    error_message = "Lambda architecture must be arm64 or x86_64."
  }
}

variable "lambda_log_retention_days" {
  description = "Number of days to keep the function's and API Gateway's logs in CloudWatch Logs."
  type        = number
  default     = 30

  validation {
    condition     = contains([0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.lambda_log_retention_days)
    error_message = "lambda_log_retention_days must be a valid CloudWatch Logs retention period."
  }
}

variable "lambda_environment_variables" {
  description = "Additional environment variables for the function. They override the module's."
  type        = map(string)
  default     = {}
}

variable "vpc_config" {
  description = "Runs the function in a VPC. It then needs a route to GitHub, and to the STS, KMS, SSM and DynamoDB endpoints, through NAT or VPC endpoints."
  type = object({
    subnet_ids         = list(string)
    security_group_ids = list(string)
  })
  default = null

  validation {
    condition     = var.vpc_config == null || try(length(var.vpc_config.subnet_ids) > 0 && length(var.vpc_config.security_group_ids) > 0, false)
    error_message = "vpc_config needs at least one subnet and one security group."
  }
}

# ============================================================= api gateway ===

variable "api_gateway_config" {
  description = "Throttling of the HTTP API's `$default` stage. Requests above the limits get `429`. Each agent makes about one request every 8 seconds."
  type = object({
    throttling_burst_limit = optional(number, 100)
    throttling_rate_limit  = optional(number, 50)
  })
  default = {}

  validation {
    condition     = var.api_gateway_config.throttling_burst_limit >= 0 && var.api_gateway_config.throttling_rate_limit >= 0
    error_message = "API Gateway throttling limits must not be negative."
  }
}

variable "domain_config" {
  description = "A custom domain for the HTTP API, with an ACM certificate in this region. With `route53_zone_id`, the module creates the domain's alias record in that zone; without it, point the domain at the `api_gateway_domain_target` output."
  type = object({
    enabled         = optional(bool, false)
    domain_name     = optional(string, "")
    certificate_arn = optional(string, "")
    route53_zone_id = optional(string, "")
  })
  default = {}

  validation {
    condition     = !var.domain_config.enabled || can(regex("^([a-z0-9]([-a-z0-9]*[a-z0-9])?\\.)+[a-z]{2,}$", var.domain_config.domain_name))
    error_message = "domain_config.domain_name must be a lowercase domain name, such as sealer.example.com."
  }

  validation {
    condition     = !var.domain_config.enabled || can(regex("^arn:aws[a-z-]*:acm:[a-z0-9-]+:[0-9]{12}:certificate/", var.domain_config.certificate_arn))
    error_message = "domain_config.certificate_arn must be an ACM certificate ARN."
  }
}

# ==================================================================== tick ===

variable "tick_config" {
  description = "EventBridge Scheduler schedule that invokes the function with `{\"sealer\": \"tick\"}`, which runs reseal schedules. Without it, reseal schedules never start. The rate, 1 to 10 minutes, is also passed to the app as its tick interval."
  type = object({
    enabled             = optional(bool, true)
    schedule_expression = optional(string, "rate(1 minute)")
  })
  default = {}

  validation {
    condition     = can(regex("^rate\\((1 minute|([2-9]|10) minutes)\\)$", var.tick_config.schedule_expression))
    error_message = "tick_config.schedule_expression must be a rate of 1 to 10 minutes, such as rate(1 minute) or rate(5 minutes)."
  }
}
