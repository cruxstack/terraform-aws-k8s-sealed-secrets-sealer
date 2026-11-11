terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.72.0"
    }
  }
}

provider "aws" {
  region = "us-east-2"
}

module "sealer" {
  source = "../../"

  # naming context
  namespace   = "eg"
  environment = "ue2"
  stage       = "tools"
  name        = "sealer"

  # k8s-sealed-secrets-sealer release to deploy
  app_version = "v0.10.0"

  # two envs on one url; each has its own transit key (in the env's account),
  # agent registry and table
  envs = {
    dev = {
      kms_transit_key_arn = var.dev_transit_key_arn
      registry = yamlencode({
        issuers = []
        agents = [
          {
            id           = "dev-use1-blue"
            cluster      = "dev-use1-blue"
            region       = "use1"
            capabilities = ["seal", "keys", "renewal", "cleanup", "reseal"]
            identity     = { aws = { roleArn = "arn:aws:iam::222222222222:role/sealer-agent-dev-use1-blue" } }
          },
        ]
      })
    }
    prod = {
      kms_transit_key_arn = var.prod_transit_key_arn
      # or keep the registry in a parameter you manage
      registry_parameter_arn = var.prod_registry_parameter_arn
      # only prod-sealers may use prod; platform administers every env
      allowed_teams = ["prod-sealers"]
      # prod's own admin token may revoke, reinstate and delete keys
      admin_token_key_changes = true
    }
  }

  control_plane_config = {
    admin_teams = ["platform"]
  }

  # one github app reads repositories, opens pull requests and signs people in
  github_app_config = {
    org           = var.github_org
    app_id        = var.github_app_id
    private_key   = var.github_app_private_key
    client_id     = var.github_app_client_id
    client_secret = var.github_app_client_secret
  }

  # a shared token that reads every env's fleet, for monitoring, and prod's
  # own; both are generated
  admin_token_config = {
    enabled    = true
    env_tokens = { prod = "" }
  }

  domain_config = {
    enabled         = true
    domain_name     = var.domain_name
    certificate_arn = var.certificate_arn
    route53_zone_id = var.route53_zone_id
  }

  lambda_config = {
    architecture = "arm64"
    timeout      = 60
  }
}

# ---------------------------------------------------------------- variables ---

variable "dev_transit_key_arn" {
  type        = string
  description = "ARN of the dev env's transit key, in the dev account"
}

variable "prod_transit_key_arn" {
  type        = string
  description = "ARN of the prod env's transit key, in the prod account"
}

variable "prod_registry_parameter_arn" {
  type        = string
  description = "ARN of the SSM parameter holding the prod env's agent registry"
}

variable "github_org" {
  type        = string
  description = "GitHub organization name"
}

variable "github_app_id" {
  type        = string
  description = "GitHub App ID"
}

variable "github_app_private_key" {
  type        = string
  sensitive   = true
  description = "GitHub App private key (PEM), or an SSM parameter ARN"
}

variable "github_app_client_id" {
  type        = string
  description = "GitHub App client ID"
}

variable "github_app_client_secret" {
  type        = string
  sensitive   = true
  description = "GitHub App client secret, or an SSM parameter ARN"
}

variable "domain_name" {
  type        = string
  description = "Domain people and agents reach the control plane at, such as sealer.example.com"
}

variable "certificate_arn" {
  type        = string
  description = "ARN of an ACM certificate for the domain, in this region"
}

variable "route53_zone_id" {
  type        = string
  description = "Route 53 zone to create the domain's record in"
}

# ------------------------------------------------------------------ outputs ---

output "url" {
  description = "URL of the control plane, for people and the agents' controlPlane.url"
  value       = module.sealer.url
}

output "oauth_callback_url" {
  description = "Callback URL to set in the GitHub App's settings"
  value       = module.sealer.oauth_callback_url
}

output "lambda_role_arn" {
  description = "Role each env's transit key policy allows kms:GenerateDataKey"
  value       = module.sealer.lambda_role_arn
}

output "admin_token" {
  description = "Shared admin API token"
  value       = module.sealer.admin_token
  sensitive   = true
}

output "env_admin_tokens" {
  description = "Admin API tokens of the envs with their own"
  value       = module.sealer.env_admin_tokens
  sensitive   = true
}
