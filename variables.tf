# ===================================================================== app ===

variable "envs" {
  description = "Envs to serve, by name: `kms_transit_key_arn`, `registry` or `registry_parameter_arn`, and optionally `dynamodb_table`, `allowed_teams`, `admin_teams`, `admin_token_key_changes`, `env_annotation`, `region_annotation`, `discovery_file_globs` and `key_renew_period`. See Envs in the README."
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
    condition = alltrue([
      for name in keys(var.envs) :
      can(regex("^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$", name)) &&
      !contains(["agent", "api", "assets", "auth", "fleet", "healthz", "login", "readyz", "repos", "secrets", "static"], name)
    ])
    error_message = "Env names must be DNS labels, and not one of the UI's paths (api, secrets, fleet, ...)."
  }

  validation {
    condition     = alltrue([for env in var.envs : can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$", env.kms_transit_key_arn))])
    error_message = "kms_transit_key_arn must be a KMS key ARN, not an alias."
  }

  # the replicas of a multi-Region key are one key
  validation {
    condition = length(distinct([
      for env in var.envs : replace(env.kms_transit_key_arn, "/^(arn:[^:]+:kms:)[^:]+(:[0-9]+:key/mrk-)/", "$${1}*$${2}")
    ])) == length(var.envs)
    error_message = "Each env needs its own transit key."
  }

  validation {
    condition     = alltrue([for env in var.envs : (env.registry == "") != (env.registry_parameter_arn == "")])
    error_message = "Each env needs exactly one of registry and registry_parameter_arn."
  }

  validation {
    condition     = alltrue([for env in var.envs : env.registry == "" || (can(yamldecode(env.registry).agents[0]) && length(env.registry) <= 8192)])
    error_message = "registry must be YAML listing at least one agent, in at most 8192 characters."
  }

  validation {
    condition = alltrue([
      for env in var.envs :
      env.registry_parameter_arn == "" || can(regex("^arn:aws(-[a-z]+)*:ssm:[a-z0-9-]+:[0-9]{12}:parameter/[A-Za-z0-9_./-]+$", env.registry_parameter_arn))
    ])
    error_message = "registry_parameter_arn must be an SSM parameter ARN."
  }

  validation {
    condition = alltrue([
      for env in var.envs :
      try(env.dynamodb_table.kms_key_arn, "") == "" || can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$", env.dynamodb_table.kms_key_arn))
    ])
    error_message = "dynamodb_table.kms_key_arn must be a KMS key ARN."
  }

  validation {
    condition = alltrue(flatten([
      for env in var.envs : [
        for key in [env.env_annotation, env.region_annotation] :
        key == "" || can(regex("^([a-z0-9]([-a-z0-9]*[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*/)?[A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?$", key))
      ]
    ]))
    error_message = "env_annotation and region_annotation must be annotation keys, such as example.com/env."
  }

  validation {
    condition     = alltrue([for env in var.envs : env.key_renew_period == "" || can(regex("^([0-9]+(\\.[0-9]+)?(ns|us|µs|ms|s|m|h))+$", env.key_renew_period))])
    error_message = "key_renew_period must be a duration, such as 720h."
  }
}

variable "github_app_config" {
  description = "The GitHub App that reads repositories, opens pull requests and signs people in. `private_key` and `client_secret` may be SSM parameter ARNs; `url` and `api_url` are for GitHub Enterprise Server."
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
    condition     = alltrue([for u in [var.github_app_config.url, var.github_app_config.api_url] : u == "" || can(regex("^https://[^/?#]+", u))])
    error_message = "github_app_config.url and api_url must be https URLs."
  }
}

variable "control_plane_config" {
  description = "Settings every env shares: `allowed_teams`, `admin_teams`, `user_session_ttl`, `public_url`, `agent_audience`, `aws_sts_hosts`, `env_annotation`, `region_annotation`, `discovery_file_globs` and `key_renew_period`. See Shared Settings in the README."
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
    error_message = "user_session_ttl and key_renew_period must be durations, such as 8h."
  }

  validation {
    condition     = var.control_plane_config.public_url == "" || can(regex("^https://[^/?#@]+/?$", var.control_plane_config.public_url))
    error_message = "public_url must be an https URL without a path."
  }

  validation {
    condition     = var.control_plane_config.agent_audience == "" || can(regex("^https?://[^/?#]+", var.control_plane_config.agent_audience))
    error_message = "agent_audience must be a URL."
  }

  validation {
    condition     = alltrue([for h in var.control_plane_config.aws_sts_hosts : can(regex("^[^/?#@ ]+$", h))])
    error_message = "aws_sts_hosts must be host names, optionally with a port."
  }

  validation {
    condition = alltrue([
      for key in [var.control_plane_config.env_annotation, var.control_plane_config.region_annotation] :
      key == "" || can(regex("^([a-z0-9]([-a-z0-9]*[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*/)?[A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?$", key))
    ])
    error_message = "env_annotation and region_annotation must be annotation keys, such as example.com/env."
  }
}

# ================================================================ dynamodb ===

variable "dynamodb_config" {
  description = "`kms_key_arn` for the tables the module creates (default: a new key), and `deletion_protection_enabled`. The tables hold escrowed keys; turn protection off only to destroy an env."
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

# ===================================================================== ssm ===

variable "session_keys_config" {
  description = "`agent_session_key` and `user_session_key`: at least 32 bytes, or SSM parameter ARNs. Generated when empty."
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
  description = "Admin API tokens: a shared one when `enabled`, and envs' own in `env_tokens`. Each is at least 32 bytes or an SSM parameter ARN, and generated when empty."
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
  description = "`parameter_prefix` of the module's parameters (default `/<id>/`), and `kms_key_arn` for its secrets (default `aws/ssm`)."
  type = object({
    parameter_prefix = optional(string, "")
    kms_key_arn      = optional(string, "")
  })
  default = {}

  validation {
    condition     = var.ssm_config.parameter_prefix == "" || can(regex("^/([A-Za-z0-9_.-]+/)+$", var.ssm_config.parameter_prefix))
    error_message = "ssm_config.parameter_prefix must start and end with a slash."
  }

  validation {
    condition     = var.ssm_config.kms_key_arn == "" || can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$", var.ssm_config.kms_key_arn))
    error_message = "ssm_config.kms_key_arn must be a KMS key ARN."
  }
}

variable "ssm_parameter_arns" {
  description = "Other SSM parameter ARNs the function may read, for settings set to ARNs in `lambda_environment_variables`."
  type        = list(string)
  default     = []
}

# ================================================================== lambda ===

variable "app_version" {
  description = "Release of k8s-sealed-secrets-sealer to deploy."
  type        = string
  default     = "v0.10.0"

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?$", var.app_version))
    error_message = "app_version must be a release tag, such as v0.10.0."
  }
}

variable "app_repo" {
  description = "GitHub repository of the release, as `owner/name`, for forks."
  type        = string
  default     = "cruxstack/k8s-sealed-secrets-sealer"

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$", var.app_repo))
    error_message = "app_repo must be owner/name."
  }
}

variable "app_force_rebuild_id" {
  description = "Change to download the function's code again."
  type        = string
  default     = ""
}

variable "log_level" {
  description = "Log level: `debug`, `info`, `warn` or `error`."
  type        = string
  default     = "info"

  validation {
    condition     = contains(["debug", "info", "warn", "error"], var.log_level)
    error_message = "log_level must be debug, info, warn or error."
  }
}

variable "log_format" {
  description = "Log format: `json` or `text`."
  type        = string
  default     = "json"

  validation {
    condition     = contains(["json", "text"], var.log_format)
    error_message = "log_format must be json or text."
  }
}

variable "lambda_config" {
  description = "`memory_size`, `timeout`, `architecture` and `reserved_concurrent_executions`. The timeout must be at least 35 seconds: polls hold 25, and ticks stop 10 before it."
  type = object({
    memory_size                    = optional(number, 256)
    timeout                        = optional(number, 60)
    architecture                   = optional(string, "arm64")
    reserved_concurrent_executions = optional(number, -1)
  })
  default = {}

  validation {
    condition     = var.lambda_config.timeout >= 35 && var.lambda_config.timeout <= 900
    error_message = "lambda_config.timeout must be between 35 and 900 seconds."
  }
}

variable "lambda_log_retention_days" {
  description = "Days to keep the function's and the API's logs."
  type        = number
  default     = 30
}

variable "lambda_environment_variables" {
  description = "More environment variables for the function; they override the module's."
  type        = map(string)
  default     = {}
}

variable "vpc_config" {
  description = "`subnet_ids` and `security_group_ids` to run the function in a VPC, which needs a route to GitHub, STS, KMS, SSM and DynamoDB."
  type = object({
    subnet_ids         = list(string)
    security_group_ids = list(string)
  })
  default = null
}

# ============================================================= api gateway ===

variable "api_gateway_config" {
  description = "`throttling_burst_limit` and `throttling_rate_limit` of the HTTP API."
  type = object({
    throttling_burst_limit = optional(number, 100)
    throttling_rate_limit  = optional(number, 50)
  })
  default = {}
}

# ----------------------------------------------------------- custom domain ---

variable "domain_config" {
  description = "A custom domain: `domain_name`, an ACM `certificate_arn` in this region, and optionally a `route53_zone_id` for its record."
  type = object({
    enabled         = optional(bool, false)
    domain_name     = optional(string, "")
    certificate_arn = optional(string, "")
    route53_zone_id = optional(string, "")
  })
  default = {}

  validation {
    condition     = !var.domain_config.enabled || (var.domain_config.domain_name != "" && var.domain_config.certificate_arn != "")
    error_message = "domain_config needs domain_name and certificate_arn."
  }
}

# =============================================================== scheduler ===

variable "tick_config" {
  description = "The tick schedule that runs reseal schedules. Its rate, 1 to 10 minutes, is also the app's tick interval."
  type = object({
    enabled             = optional(bool, true)
    schedule_expression = optional(string, "rate(1 minute)")
  })
  default = {}

  validation {
    condition     = can(regex("^rate\\((1 minute|([2-9]|10) minutes)\\)$", var.tick_config.schedule_expression))
    error_message = "tick_config.schedule_expression must be rate(1 minute) to rate(10 minutes)."
  }
}
