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

  namespace   = "eg"
  environment = "ue2"
  stage       = "tools"
  name        = "sealer"

  app_version = "v0.11.0"

  # two envs on one url, each with its own transit key, registry and table
  envs = {
    dev = {
      kms_transit_key_arn = var.dev_transit_key_arn
      registry = yamlencode({
        issuers = []
        agents = [{
          id           = "dev-use1-blue"
          cluster      = "dev-use1-blue"
          region       = "use1"
          capabilities = ["seal", "keys", "renewal", "cleanup", "reseal"]
          identity     = { aws = { roleArn = "arn:aws:iam::222222222222:role/sealer-agent-dev-use1-blue" } }
        }]
      })
    }
    prod = {
      kms_transit_key_arn     = var.prod_transit_key_arn
      registry_parameter_arn  = var.prod_registry_parameter_arn
      allowed_teams           = ["prod-sealers"]
      admin_token_key_changes = true
    }
  }

  control_plane_config = {
    admin_teams = ["platform"]
  }

  github_app_config = {
    org           = var.github_org
    app_id        = var.github_app_id
    private_key   = var.github_app_private_key
    client_id     = var.github_app_client_id
    client_secret = var.github_app_client_secret
  }

  # a shared read-only token for monitoring, and prod's own, both generated
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
}

# ---------------------------------------------------------------- variables ---

variable "dev_transit_key_arn" {
  type        = string
  description = "Dev transit key ARN, in the dev account"
}

variable "prod_transit_key_arn" {
  type        = string
  description = "Prod transit key ARN, in the prod account"
}

variable "prod_registry_parameter_arn" {
  type        = string
  description = "SSM parameter holding the prod env's registry"
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
  description = "Domain of the control plane, such as sealer.example.com"
}

variable "certificate_arn" {
  type        = string
  description = "ACM certificate for the domain, in this region"
}

variable "route53_zone_id" {
  type        = string
  description = "Route 53 zone for the domain's record"
}

# ------------------------------------------------------------------ outputs ---

output "url" {
  description = "URL of the control plane"
  value       = module.sealer.url
}

output "oauth_callback_url" {
  description = "Callback URL for the GitHub App"
  value       = module.sealer.oauth_callback_url
}

output "lambda_role_arn" {
  description = "Role to allow on each env's transit key"
  value       = module.sealer.lambda_role_arn
}

output "admin_token" {
  description = "Shared admin API token"
  value       = module.sealer.admin_token
  sensitive   = true
}

output "env_admin_tokens" {
  description = "Envs' own admin API tokens"
  value       = module.sealer.env_admin_tokens
  sensitive   = true
}
