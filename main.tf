# ================================================================== locals ===

locals {
  enabled = module.this.enabled

  aws_account_id  = data.aws_caller_identity.current.account_id
  aws_region_name = data.aws_region.current.region
  aws_partition   = data.aws_partition.current.partition

  goarch    = var.lambda_config.architecture == "arm64" ? "arm64" : "amd64"
  env_names = sort(keys(var.envs))
  multi_env = length(var.envs) > 1
}

# ==================================================================== data ===

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

# ================================================================ dynamodb ===

# each env's table holds its escrowed sealing keys, which nothing can rebuild

locals {
  table_names    = { for name, env in var.envs : name => try(env.dynamodb_table.name, "${module.this.id}-${name}") }
  created_tables = { for name, env in var.envs : name => local.table_names[name] if env.dynamodb_table == null }
  table_arns = {
    for name, table in local.table_names : name => "arn:${local.aws_partition}:dynamodb:${local.aws_region_name}:${local.aws_account_id}:table/${table}"
  }

  create_table_key  = local.enabled && length(local.created_tables) > 0 && var.dynamodb_config.kms_key_arn == ""
  table_kms_key_arn = var.dynamodb_config.kms_key_arn != "" ? var.dynamodb_config.kms_key_arn : one(aws_kms_key.dynamodb[*].arn)

  # the keys given for the tables in use, which must be in the tables' region
  given_table_kms_key_arns = compact(concat(
    length(local.created_tables) > 0 ? [var.dynamodb_config.kms_key_arn] : [],
    [for env in var.envs : try(env.dynamodb_table.kms_key_arn, "")],
  ))
}

resource "aws_dynamodb_table" "this" {
  for_each = local.enabled ? local.created_tables : {}

  name                        = each.value
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "pk"
  range_key                   = "sk"
  deletion_protection_enabled = var.dynamodb_config.deletion_protection_enabled

  attribute {
    name = "pk"
    type = "S"
  }

  attribute {
    name = "sk"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = local.table_kms_key_arn
  }

  tags = module.this.tags
}

resource "aws_kms_key" "dynamodb" {
  count = local.create_table_key ? 1 : 0

  description             = "Encrypts the DynamoDB tables of ${module.this.id}"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.dynamodb_key[0].json

  tags = module.this.tags
}

resource "aws_kms_alias" "dynamodb" {
  count = local.create_table_key ? 1 : 0

  name          = "alias/${module.this.id}-dynamodb"
  target_key_id = aws_kms_key.dynamodb[0].key_id
}

data "aws_iam_policy_document" "dynamodb_key" {
  count = local.create_table_key ? 1 : 0

  statement {
    sid       = "AccountAdministersTheKey"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.aws_partition}:iam::${local.aws_account_id}:root"]
    }
  }
}

# ===================================================================== ssm ===

locals {
  ssm_parameter_prefix = coalesce(var.ssm_config.parameter_prefix, "/${module.this.id}/")

  # the config objects are sensitive as a whole; these reveal nothing
  admin_enabled   = nonsensitive(var.admin_token_config.enabled)
  env_token_names = nonsensitive(toset(keys(var.admin_token_config.env_tokens)))

  # each secret by its parameter name: a value, a parameter arn, or "" to generate
  secrets = merge(
    {
      APP_GITHUB_APP_PRIVATE_KEY     = var.github_app_config.private_key
      APP_GITHUB_OAUTH_CLIENT_SECRET = var.github_app_config.client_secret
      APP_AGENT_SESSION_KEY          = var.session_keys_config.agent_session_key
      APP_USER_SESSION_KEY           = var.session_keys_config.user_session_key
    },
    local.admin_enabled ? { APP_ADMIN_TOKEN = var.admin_token_config.token } : {},
    { for env in local.env_token_names : "envs/${env}/admin-token" => var.admin_token_config.env_tokens[env] },
  )
  secret_names = nonsensitive(toset(keys(local.secrets)))

  # given as parameter arns, by the app's own pattern, and passed on as they are
  given_secret_arns = {
    for name in local.secret_names : name => nonsensitive(local.secrets[name])
    if nonsensitive(can(regex("^arn:aws(-[a-z]+)*:ssm:[a-z0-9-]+:[0-9]{12}:parameter/[A-Za-z0-9_./-]+$", local.secrets[name])))
  }
  generated_secrets = toset([for name in local.secret_names : name if nonsensitive(local.secrets[name] == "")])
  secret_arns = {
    for name in local.secret_names : name => lookup(local.given_secret_arns, name, try(aws_ssm_parameter.secret[name].arn, null))
  }
}

resource "aws_ssm_parameter" "secret" {
  for_each = local.enabled ? setsubtract(local.secret_names, keys(local.given_secret_arns)) : toset([])

  name        = "${local.ssm_parameter_prefix}${each.key}"
  description = "${each.key} of ${module.this.id}"
  type        = "SecureString"
  value       = contains(local.generated_secrets, each.key) ? random_password.secret[each.key].result : local.secrets[each.key]
  key_id      = var.ssm_config.kms_key_arn != "" ? var.ssm_config.kms_key_arn : null

  tags = module.this.tags
}

resource "random_password" "secret" {
  for_each = local.enabled ? local.generated_secrets : toset([])

  length  = 64
  special = false
}

resource "aws_ssm_parameter" "registry" {
  for_each = local.enabled ? { for name, env in var.envs : name => env.registry if env.registry != "" } : {}

  name           = "${local.ssm_parameter_prefix}envs/${each.key}/registry"
  description    = "Agent registry of the ${each.key} env of ${module.this.id}"
  type           = "String"
  tier           = length(each.value) > 4096 ? "Advanced" : "Standard"
  insecure_value = each.value

  tags = module.this.tags
}

# lambda's environment holds only 4 KB, which several envs can outgrow
resource "aws_ssm_parameter" "envs" {
  count = local.enabled && local.multi_env ? 1 : 0

  name           = "${local.ssm_parameter_prefix}APP_ENVS"
  description    = "Envs served by ${module.this.id}"
  type           = "String"
  tier           = length(local.app_envs) > 4096 ? "Advanced" : "Standard"
  insecure_value = local.app_envs

  tags = module.this.tags
}

# ================================================================== lambda ===

locals {
  # each env's settings, as APP_ENVS names them; unset ones are left out
  env_settings = {
    for name, env in var.envs : name => merge(
      {
        name            = name
        dynamodbTable   = local.table_names[name]
        kmsTransitKeyId = env.kms_transit_key_arn
        registry        = env.registry_parameter_arn != "" ? env.registry_parameter_arn : try(aws_ssm_parameter.registry[name].arn, null)
      },
      env.allowed_teams != null ? { allowedTeams = env.allowed_teams } : {},
      env.admin_teams != null ? { adminTeams = env.admin_teams } : {},
      contains(local.env_token_names, name) ? { adminToken = local.secret_arns["envs/${name}/admin-token"] } : {},
      env.admin_token_key_changes ? { adminTokenKeyChanges = true } : {},
      env.env_annotation != "" ? { envAnnotation = env.env_annotation } : {},
      env.region_annotation != "" ? { regionAnnotation = env.region_annotation } : {},
      length(env.discovery_file_globs) > 0 ? { discoveryFileGlobs = env.discovery_file_globs } : {},
      env.key_renew_period != "" ? { keyRenewPeriod = env.key_renew_period } : {},
    )
  }
  # APP_ENVS is yaml, of which json is a subset
  app_envs = jsonencode({ envs = [for name in local.env_names : local.env_settings[name]] })

  # the app variable each setting maps to with a single env
  env_setting_variables = {
    name                 = "APP_ENV_NAME"
    dynamodbTable        = "APP_DYNAMODB_TABLE"
    kmsTransitKeyId      = "APP_KMS_TRANSIT_KEY_ID"
    registry             = "APP_REGISTRY"
    allowedTeams         = "APP_GITHUB_ALLOWED_TEAMS"
    adminTeams           = "APP_GITHUB_ADMIN_TEAMS"
    adminToken           = "APP_ADMIN_TOKEN"
    adminTokenKeyChanges = "APP_ADMIN_TOKEN_KEY_CHANGES"
    envAnnotation        = "APP_ENV_ANNOTATION"
    regionAnnotation     = "APP_REGION_ANNOTATION"
    discoveryFileGlobs   = "APP_DISCOVERY_FILE_GLOBS"
    keyRenewPeriod       = "APP_KEY_RENEW_PERIOD"
  }

  public_url = (
    var.control_plane_config.public_url != "" ? trimsuffix(var.control_plane_config.public_url, "/") :
    var.domain_config.enabled ? "https://${var.domain_config.domain_name}" :
    try(aws_apigatewayv2_api.this[0].api_endpoint, "")
  )

  # the env's own settings come last, so they replace the shared ones
  app_environment = merge(
    {
      APP_LOG_LEVEL                  = var.log_level
      APP_LOG_FORMAT                 = var.log_format
      APP_PUBLIC_URL                 = local.public_url
      APP_AGENT_AUDIENCE             = var.control_plane_config.agent_audience
      APP_AWS_STS_HOSTS              = join(",", var.control_plane_config.aws_sts_hosts)
      APP_GITHUB_ORG                 = nonsensitive(var.github_app_config.org)
      APP_GITHUB_APP_ID              = nonsensitive(var.github_app_config.app_id)
      APP_GITHUB_APP_INSTALLATION_ID = nonsensitive(var.github_app_config.installation_id)
      APP_GITHUB_OAUTH_CLIENT_ID     = nonsensitive(var.github_app_config.client_id)
      APP_GITHUB_URL                 = nonsensitive(var.github_app_config.url)
      APP_GITHUB_API_URL             = nonsensitive(var.github_app_config.api_url)
      APP_GITHUB_ALLOWED_TEAMS       = join(",", var.control_plane_config.allowed_teams)
      APP_GITHUB_ADMIN_TEAMS         = join(",", var.control_plane_config.admin_teams)
      APP_USER_SESSION_TTL           = var.control_plane_config.user_session_ttl
      APP_ENV_ANNOTATION             = var.control_plane_config.env_annotation
      APP_REGION_ANNOTATION          = var.control_plane_config.region_annotation
      APP_DISCOVERY_FILE_GLOBS       = join(",", var.control_plane_config.discovery_file_globs)
      APP_KEY_RENEW_PERIOD           = var.control_plane_config.key_renew_period
      APP_TICK_INTERVAL              = var.tick_config.enabled ? "${regex("([0-9]+) minute", var.tick_config.schedule_expression)[0]}m" : ""
    },
    # envs' own admin tokens go in their settings
    { for name, arn in local.secret_arns : name => arn if startswith(name, "APP_") },
    local.multi_env ? { APP_ENVS = try(aws_ssm_parameter.envs[0].arn, null) } : {
      for key, value in local.env_settings[local.env_names[0]] :
      local.env_setting_variables[key] => try(join(",", value), tostring(value))
    },
  )

  # ssm settings are read at start, so a change must replace the instances
  config_revision = substr(sha256(jsonencode({
    envs    = local.app_envs
    secrets = { for name, param in aws_ssm_parameter.secret : name => param.version }
  })), 0, 16)
}

resource "aws_lambda_function" "this" {
  count = local.enabled ? 1 : 0

  function_name                  = module.this.id
  description                    = "k8s-sealed-secrets-sealer control plane ${var.app_version}"
  role                           = aws_iam_role.this[0].arn
  handler                        = "bootstrap"
  runtime                        = "provided.al2023"
  architectures                  = [var.lambda_config.architecture]
  memory_size                    = var.lambda_config.memory_size
  timeout                        = var.lambda_config.timeout
  reserved_concurrent_executions = var.lambda_config.reserved_concurrent_executions
  filename                       = buildkit_artifact.app[0].artifact_path
  source_code_hash               = buildkit_artifact.app[0].artifact_sha256

  environment {
    # unset settings are left out, so the app applies its defaults
    variables = merge(
      { for name, value in local.app_environment : name => value if value != null && value != "" },
      { SEALER_CONFIG_REVISION = local.config_revision },
      var.lambda_environment_variables,
    )
  }

  dynamic "vpc_config" {
    for_each = var.vpc_config != null ? [var.vpc_config] : []

    content {
      subnet_ids         = vpc_config.value.subnet_ids
      security_group_ids = vpc_config.value.security_group_ids
    }
  }

  lifecycle {
    precondition {
      condition     = alltrue([for name in local.env_token_names : contains(local.env_names, name)])
      error_message = "admin_token_config.env_tokens names an unknown env."
    }

    precondition {
      condition     = alltrue([for name, env in var.envs : !env.admin_token_key_changes || local.admin_enabled || contains(local.env_token_names, name)])
      error_message = "admin_token_key_changes needs the shared admin token or the env's own."
    }

    precondition {
      condition     = length(distinct(values(local.table_names))) == length(local.table_names)
      error_message = "Each env needs its own DynamoDB table."
    }

    # a table restored from another region's backup needs a key in this one
    precondition {
      condition     = alltrue([for arn in local.given_table_kms_key_arns : split(":", arn)[3] == local.aws_region_name])
      error_message = "The tables' KMS keys must be in ${local.aws_region_name}, where the tables are."
    }

    precondition {
      condition     = var.ssm_config.kms_key_arn == "" || split(":", var.ssm_config.kms_key_arn)[3] == local.aws_region_name
      error_message = "ssm_config.kms_key_arn must be a key in ${local.aws_region_name}, where the parameters are."
    }
  }

  # the environment names the tables without referencing them
  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_dynamodb_table.this,
    aws_iam_role_policy.this,
  ]

  tags = module.this.tags
}

resource "aws_cloudwatch_log_group" "lambda" {
  count = local.enabled ? 1 : 0

  name              = "/aws/lambda/${module.this.id}"
  retention_in_days = var.lambda_log_retention_days

  tags = module.this.tags
}

data "buildkit_context" "app" {
  count = local.enabled ? 1 : 0

  path = abspath("${path.module}/assets/lambda-function")
}

resource "buildkit_artifact" "app" {
  count = local.enabled ? 1 : 0

  build_context     = abspath("${path.module}/assets/lambda-function")
  dockerfile        = "Dockerfile"
  target            = "package"
  artifact_src_path = "/tmp/package.zip"
  artifact_src_type = "zip"
  artifact_dst_path = "${path.module}/dist/${module.this.id}/package.zip"

  build_args = {
    APP_VERSION = var.app_version
    APP_REPO    = var.app_repo
    GOARCH      = local.goarch
  }

  triggers = {
    context          = data.buildkit_context.app[0].digest
    app_version      = var.app_version
    app_repo         = var.app_repo
    goarch           = local.goarch
    force_rebuild_id = var.app_force_rebuild_id
  }
}

# --------------------------------------------------------------------- iam ---

locals {
  # dynamodb uses these on the function's behalf
  table_kms_key_arns = concat(
    length(local.created_tables) > 0 ? [local.table_kms_key_arn] : [],
    distinct([for env in var.envs : env.dynamodb_table.kms_key_arn if try(env.dynamodb_table.kms_key_arn, "") != ""]),
  )

  parameter_arns = concat(
    values(aws_ssm_parameter.secret)[*].arn,
    values(aws_ssm_parameter.registry)[*].arn,
    aws_ssm_parameter.envs[*].arn,
    distinct(concat(
      values(local.given_secret_arns),
      [for env in var.envs : env.registry_parameter_arn if env.registry_parameter_arn != ""],
      var.ssm_parameter_arns,
    )),
  )
}

resource "aws_iam_role" "this" {
  count = local.enabled ? 1 : 0

  name        = module.this.id
  description = "Role of the ${module.this.id} Lambda function"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = module.this.tags
}

resource "aws_iam_role_policy" "this" {
  count = local.enabled ? 1 : 0

  name   = module.this.id
  role   = aws_iam_role.this[0].id
  policy = data.aws_iam_policy_document.this[0].json
}

data "aws_iam_policy_document" "this" {
  count = local.enabled ? 1 : 0

  statement {
    sid       = "CloudWatchLogsAccess"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.lambda[0].arn}:*"]
  }

  # every call the app's store makes; IAM checks TransactWriteItems part by part
  statement {
    sid    = "Tables"
    effect = "Allow"
    actions = [
      "dynamodb:BatchGetItem",
      "dynamodb:ConditionCheckItem",
      "dynamodb:DeleteItem",
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:Query",
      "dynamodb:UpdateItem",
    ]
    resources = values(local.table_arns)
  }

  dynamic "statement" {
    for_each = length(local.table_kms_key_arns) > 0 ? [1] : []

    content {
      sid       = "TableKeys"
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = local.table_kms_key_arns

      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["dynamodb.${local.aws_region_name}.amazonaws.com"]
      }
    }
  }

  # the same conditions as the transit key's own policy
  dynamic "statement" {
    for_each = local.env_names

    content {
      sid       = "TransitKey${statement.key}"
      effect    = "Allow"
      actions   = ["kms:GenerateDataKey"]
      resources = [var.envs[statement.value].kms_transit_key_arn]

      condition {
        test     = "StringEquals"
        variable = "kms:EncryptionContext:env"
        values   = [statement.value]
      }

      condition {
        test     = "StringEquals"
        variable = "kms:EncryptionContext:purpose"
        values   = ["seal"]
      }
    }
  }

  dynamic "statement" {
    for_each = length(local.parameter_arns) > 0 ? [1] : []

    content {
      sid       = "ReadParameters"
      effect    = "Allow"
      actions   = ["ssm:GetParameter"]
      resources = local.parameter_arns
    }
  }

  dynamic "statement" {
    for_each = var.ssm_config.kms_key_arn != "" ? [1] : []

    content {
      sid       = "ParametersKey"
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = [var.ssm_config.kms_key_arn]

      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["ssm.${local.aws_region_name}.amazonaws.com"]
      }
    }
  }

  dynamic "statement" {
    for_each = var.vpc_config != null ? [1] : []

    content {
      sid    = "VpcNetworkInterfaces"
      effect = "Allow"
      actions = [
        "ec2:AssignPrivateIpAddresses",
        "ec2:CreateNetworkInterface",
        "ec2:DeleteNetworkInterface",
        "ec2:DescribeNetworkInterfaces",
        "ec2:DescribeSubnets",
        "ec2:UnassignPrivateIpAddresses",
      ]
      resources = ["*"]
    }
  }
}

# ============================================================= api gateway ===

# the app has no base path, so every path must reach it unchanged

resource "aws_apigatewayv2_api" "this" {
  count = local.enabled ? 1 : 0

  name          = module.this.id
  description   = "k8s-sealed-secrets-sealer control plane"
  protocol_type = "HTTP"

  tags = module.this.tags
}

resource "aws_apigatewayv2_stage" "this" {
  count = local.enabled ? 1 : 0

  name        = "$default"
  api_id      = aws_apigatewayv2_api.this[0].id
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = var.api_gateway_config.throttling_burst_limit
    throttling_rate_limit  = var.api_gateway_config.throttling_rate_limit
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gateway[0].arn
    format = jsonencode({
      requestId         = "$context.requestId"
      ip                = "$context.identity.sourceIp"
      requestTime       = "$context.requestTime"
      httpMethod        = "$context.httpMethod"
      path              = "$context.path"
      routeKey          = "$context.routeKey"
      status            = "$context.status"
      protocol          = "$context.protocol"
      responseLength    = "$context.responseLength"
      integrationStatus = "$context.integrationStatus"
      integrationError  = "$context.integrationErrorMessage"
      integrationTime   = "$context.integrationLatency"
    })
  }

  tags = module.this.tags
}

resource "aws_cloudwatch_log_group" "api_gateway" {
  count = local.enabled ? 1 : 0

  name              = "/aws/apigateway/${module.this.id}"
  retention_in_days = var.lambda_log_retention_days

  tags = module.this.tags
}

resource "aws_apigatewayv2_route" "default" {
  count = local.enabled ? 1 : 0

  api_id    = aws_apigatewayv2_api.this[0].id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.this[0].id}"
}

# the most an http api allows; agents' command polls end within 25s
resource "aws_apigatewayv2_integration" "this" {
  count = local.enabled ? 1 : 0

  api_id                 = aws_apigatewayv2_api.this[0].id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.this[0].invoke_arn
  payload_format_version = "2.0"
  timeout_milliseconds   = 30000
}

resource "aws_lambda_permission" "api_gateway" {
  count = local.enabled ? 1 : 0

  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.this[0].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this[0].execution_arn}/*/*"
}

# ----------------------------------------------------------- custom domain ---

locals {
  domain_enabled = local.enabled && var.domain_config.enabled
}

resource "aws_apigatewayv2_domain_name" "this" {
  count = local.domain_enabled ? 1 : 0

  domain_name = var.domain_config.domain_name

  domain_name_configuration {
    certificate_arn = var.domain_config.certificate_arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }

  tags = module.this.tags
}

resource "aws_apigatewayv2_api_mapping" "this" {
  count = local.domain_enabled ? 1 : 0

  api_id      = aws_apigatewayv2_api.this[0].id
  domain_name = aws_apigatewayv2_domain_name.this[0].id
  stage       = aws_apigatewayv2_stage.this[0].id
}

resource "aws_route53_record" "this" {
  count = local.domain_enabled && var.domain_config.route53_zone_id != "" ? 1 : 0

  name    = var.domain_config.domain_name
  zone_id = var.domain_config.route53_zone_id
  type    = "A"

  alias {
    name                   = aws_apigatewayv2_domain_name.this[0].domain_name_configuration[0].target_domain_name
    zone_id                = aws_apigatewayv2_domain_name.this[0].domain_name_configuration[0].hosted_zone_id
    evaluate_target_health = false
  }
}

# =============================================================== scheduler ===

# ticks run reseal schedules; without them, schedules never start

locals {
  tick_enabled = local.enabled && var.tick_config.enabled
}

resource "aws_scheduler_schedule" "tick" {
  count = local.tick_enabled ? 1 : 0

  name                = "${module.this.id}-tick"
  description         = "Reseal ticks of ${module.this.id}"
  schedule_expression = var.tick_config.schedule_expression

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.this[0].arn
    role_arn = aws_iam_role.scheduler[0].arn
    input    = jsonencode({ sealer = "tick" })

    # a late tick is no use; the next one comes anyway
    retry_policy {
      maximum_event_age_in_seconds = 60
      maximum_retry_attempts       = 0
    }
  }
}

resource "aws_iam_role" "scheduler" {
  count = local.tick_enabled ? 1 : 0

  name        = "${module.this.id}-tick"
  description = "Role of the ${module.this.id} tick schedule"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = local.aws_account_id } }
    }]
  })

  tags = module.this.tags
}

resource "aws_iam_role_policy" "scheduler" {
  count = local.tick_enabled ? 1 : 0

  name   = "${module.this.id}-tick"
  role   = aws_iam_role.scheduler[0].id
  policy = data.aws_iam_policy_document.scheduler[0].json
}

data "aws_iam_policy_document" "scheduler" {
  count = local.tick_enabled ? 1 : 0

  statement {
    sid       = "InvokeFunction"
    effect    = "Allow"
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.this[0].arn]
  }
}
