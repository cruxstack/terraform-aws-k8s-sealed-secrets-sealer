# ================================================================ dynamodb ===

output "dynamodb_tables" {
  description = "Each env's table name and ARN, by env"
  value = local.enabled ? {
    for name in local.env_names : name => { name = local.table_names[name], arn = local.table_arns[name] }
  } : null
}

output "dynamodb_kms_key_arn" {
  description = "ARN of the KMS key of the tables the module creates"
  value       = local.enabled && length(local.created_tables) > 0 ? local.table_kms_key_arn : null
}

# ===================================================================== ssm ===

output "ssm_parameter_arns" {
  description = "ARNs of the module's SSM parameters, by name under the prefix"
  value = local.enabled ? merge(
    { for name, param in aws_ssm_parameter.secret : name => param.arn },
    { for name, param in aws_ssm_parameter.registry : "envs/${name}/registry" => param.arn },
    { for param in aws_ssm_parameter.envs : "APP_ENVS" => param.arn },
  ) : null
}

output "admin_token" {
  description = "Shared admin API token, unless given as a parameter ARN"
  value       = try(aws_ssm_parameter.secret["APP_ADMIN_TOKEN"].value, null)
  sensitive   = true
}

output "env_admin_tokens" {
  description = "Envs' own admin API tokens, by env, except those given as parameter ARNs"
  value = local.enabled ? {
    for name in local.env_token_names : name => aws_ssm_parameter.secret["envs/${name}/admin-token"].value
    if !contains(keys(local.given_secret_arns), "envs/${name}/admin-token")
  } : null
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

output "lambda_log_group_name" {
  description = "Name of the function's log group"
  value       = try(aws_cloudwatch_log_group.lambda[0].name, null)
}

# --------------------------------------------------------------------- iam ---

output "lambda_role_arn" {
  description = "ARN of the function's role, for the transit key policies"
  value       = try(aws_iam_role.this[0].arn, null)
}

output "lambda_role_name" {
  description = "Name of the function's role"
  value       = try(aws_iam_role.this[0].name, null)
}

# ============================================================= api gateway ===

output "api_gateway_id" {
  description = "ID of the HTTP API"
  value       = try(aws_apigatewayv2_api.this[0].id, null)
}

output "api_gateway_endpoint" {
  description = "Default endpoint of the HTTP API"
  value       = try(aws_apigatewayv2_api.this[0].api_endpoint, null)
}

output "url" {
  description = "Public URL, for people and the agents' `controlPlane.url`"
  value       = local.enabled ? local.public_url : null
}

output "agent_audience" {
  description = "Audience the agents' `identity.audience` must equal"
  value       = local.enabled ? coalesce(var.control_plane_config.agent_audience, local.public_url) : null
}

output "oauth_callback_url" {
  description = "Callback URL for the GitHub App's settings"
  value       = local.enabled ? "${local.public_url}/api/v1/auth/callback" : null
}

# ----------------------------------------------------------- custom domain ---

output "api_gateway_domain_target" {
  description = "Alias target of the custom domain's DNS record"
  value = local.domain_enabled ? {
    domain_name    = aws_apigatewayv2_domain_name.this[0].domain_name_configuration[0].target_domain_name
    hosted_zone_id = aws_apigatewayv2_domain_name.this[0].domain_name_configuration[0].hosted_zone_id
  } : null
}

# =============================================================== scheduler ===

output "scheduler_schedule_arn" {
  description = "ARN of the tick schedule"
  value       = try(aws_scheduler_schedule.tick[0].arn, null)
}
