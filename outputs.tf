# ===================================================================== app ===

output "url" {
  description = "Public URL of the control plane, for people and for the agents' `controlPlane.url`"
  value       = local.enabled && local.public_url != "" ? local.public_url : null
}

output "agent_audience" {
  description = "Audience agents sign their logins for; the agents' `identity.audience` must equal it"
  value       = local.enabled && local.agent_audience != "" ? local.agent_audience : null
}

output "oauth_callback_url" {
  description = "Callback URL to set in the GitHub App's settings"
  value       = local.enabled && local.public_url != "" ? "${local.public_url}/api/v1/auth/callback" : null
}

output "admin_token" {
  description = "Shared admin API token, when enabled and not given as an SSM parameter ARN"
  value       = local.enabled ? lookup(local.stored_secret_values, "APP_ADMIN_TOKEN", null) : null
  sensitive   = true
}

output "env_admin_tokens" {
  description = "Admin API tokens of the envs with their own, by env, except those given as SSM parameter ARNs"
  value = local.enabled ? {
    for name in local.env_token_names : name => local.stored_secret_values["envs/${name}/admin-token"]
    if contains(local.stored_secret_names, "envs/${name}/admin-token")
  } : {}
  sensitive = true
}

# ================================================================== lambda ===

output "lambda_function_name" {
  description = "Name of the Lambda function"
  value       = try(aws_lambda_function.this[0].function_name, null)
}

output "lambda_function_arn" {
  description = "ARN of the Lambda function"
  value       = try(aws_lambda_function.this[0].arn, null)
}

output "lambda_role_arn" {
  description = "ARN of the function's IAM role, which each env's transit key policy allows kms:GenerateDataKey"
  value       = try(aws_iam_role.this[0].arn, null)
}

output "lambda_role_name" {
  description = "Name of the function's IAM role"
  value       = try(aws_iam_role.this[0].name, null)
}

output "lambda_log_group_name" {
  description = "Name of the function's log group"
  value       = try(aws_cloudwatch_log_group.lambda[0].name, null)
}

# ============================================================= api gateway ===

output "api_gateway_id" {
  description = "ID of the API Gateway HTTP API"
  value       = try(aws_apigatewayv2_api.this[0].id, null)
}

output "api_gateway_endpoint" {
  description = "Default endpoint of the HTTP API"
  value       = try(aws_apigatewayv2_api.this[0].api_endpoint, null)
}

output "api_gateway_domain_target" {
  description = "Where the custom domain's DNS record points, an alias to `domain_name` in `hosted_zone_id`; null without a custom domain"
  value = local.domain_enabled ? {
    domain_name    = aws_apigatewayv2_domain_name.this[0].domain_name_configuration[0].target_domain_name
    hosted_zone_id = aws_apigatewayv2_domain_name.this[0].domain_name_configuration[0].hosted_zone_id
  } : null
}

# ================================================================ dynamodb ===

output "dynamodb_tables" {
  description = "Each env's DynamoDB table, by env: its name and ARN"
  value = local.enabled ? {
    for name in local.env_names : name => {
      name = local.table_names[name]
      arn  = local.table_arns[name]
    }
  } : {}
}

output "dynamodb_kms_key_arn" {
  description = "ARN of the KMS key of the tables the module creates"
  value       = local.enabled && length(local.created_tables) > 0 ? local.table_kms_key_arn : null
}

# ===================================================================== ssm ===

output "ssm_parameter_arns" {
  description = "ARNs of the SSM parameters the module manages, by name under the prefix: secrets, `envs/<env>/registry` and `APP_ENVS`"
  value = merge(
    { for name, param in aws_ssm_parameter.secret : name => param.arn },
    { for name, param in aws_ssm_parameter.registry : "envs/${name}/registry" => param.arn },
    { for param in aws_ssm_parameter.envs : "APP_ENVS" => param.arn },
  )
}

# =============================================================== scheduler ===

output "scheduler_schedule_arn" {
  description = "ARN of the tick schedule, when enabled"
  value       = try(aws_scheduler_schedule.tick[0].arn, null)
}
