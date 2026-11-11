# ================================================================== locals ===

locals {
  enabled = module.this.enabled

  aws_account_id  = data.aws_caller_identity.current.account_id
  aws_region_name = data.aws_region.current.region
  aws_partition   = data.aws_partition.current.partition

  goarch = var.lambda_config.architecture == "arm64" ? "arm64" : "amd64"

  # one env runs with the app's single-env settings, several through APP_ENVS
  env_names = sort(keys(var.envs))
  multi_env = length(var.envs) > 1

  # matches the app's own test for a setting given as an ssm parameter
  ssm_arn_pattern = "^arn:aws(-[a-z]+)*:ssm:[a-z0-9-]+:[0-9]{12}:parameter/[A-Za-z0-9_./-]+$"

  # ---------------------------------------------------------------- tables ---

  created_tables = { for name, env in var.envs : name => "${module.this.id}-${name}" if env.dynamodb_table == null }
  table_names = {
    for name, env in var.envs : name => env.dynamodb_table == null ? local.created_tables[name] : env.dynamodb_table.name
  }
  table_arns = {
    for name, table in local.table_names : name => "arn:${local.aws_partition}:dynamodb:${local.aws_region_name}:${local.aws_account_id}:table/${table}"
  }

  create_table_key  = local.enabled && length(local.created_tables) > 0 && var.dynamodb_config.kms_key_arn == ""
  table_kms_key_arn = var.dynamodb_config.kms_key_arn != "" ? var.dynamodb_config.kms_key_arn : one(aws_kms_key.dynamodb[*].arn)
  # the customer managed keys of the tables the function uses, which dynamodb
  # calls kms with on its behalf
  table_kms_key_arns = concat(
    length(local.created_tables) > 0 ? [local.table_kms_key_arn] : [],
    distinct([for env in var.envs : env.dynamodb_table.kms_key_arn if try(env.dynamodb_table.kms_key_arn, "") != ""]),
  )

  # --------------------------------------------------------------- secrets ---

  ssm_parameter_prefix = var.ssm_config.parameter_prefix != "" ? var.ssm_config.parameter_prefix : "/${module.this.id}/"

  # the config objects are sensitive as a whole; these flags and names reveal
  # nothing
  admin_enabled   = nonsensitive(var.admin_token_config.enabled)
  env_token_names = nonsensitive(toset(keys(var.admin_token_config.env_tokens)))

  # each secret, by its parameter's name under the prefix: a value, an ssm
  # parameter arn, or empty to generate one
  secret_inputs = merge(
    {
      APP_GITHUB_APP_PRIVATE_KEY     = var.github_app_config.private_key
      APP_GITHUB_OAUTH_CLIENT_SECRET = var.github_app_config.client_secret
      APP_AGENT_SESSION_KEY          = var.session_keys_config.agent_session_key
      APP_USER_SESSION_KEY           = var.session_keys_config.user_session_key
    },
    local.admin_enabled ? { APP_ADMIN_TOKEN = var.admin_token_config.token } : {},
    { for name in local.env_token_names : "envs/${name}/admin-token" => var.admin_token_config.env_tokens[name] },
  )
  secret_names = toset(concat(
    ["APP_GITHUB_APP_PRIVATE_KEY", "APP_GITHUB_OAUTH_CLIENT_SECRET", "APP_AGENT_SESSION_KEY", "APP_USER_SESSION_KEY"],
    local.admin_enabled ? ["APP_ADMIN_TOKEN"] : [],
    [for name in local.env_token_names : "envs/${name}/admin-token"],
  ))
  generated_secret_names = toset([for name in local.secret_names : name if nonsensitive(local.secret_inputs[name] == "")])
  # a secret given as an ssm parameter arn is passed as is, and its parameter
  # is readable; only whether it is an arn is revealed
  given_secret_arns = {
    for name in local.secret_names : name => nonsensitive(local.secret_inputs[name])
    if nonsensitive(can(regex(local.ssm_arn_pattern, local.secret_inputs[name])))
  }
  stored_secret_names = toset([for name in local.secret_names : name if !contains(keys(local.given_secret_arns), name)])
  stored_secret_values = {
    for name in local.stored_secret_names :
    name => contains(local.generated_secret_names, name) ? try(random_password.secret[name].result, null) : local.secret_inputs[name]
  }
  secret_arns = {
    for name in local.secret_names :
    name => contains(keys(local.given_secret_arns), name) ? local.given_secret_arns[name] : try(aws_ssm_parameter.secret[name].arn, null)
  }

  # ------------------------------------------------------------------ envs ---

  inline_registries = { for name, env in var.envs : name => env.registry if env.registry_parameter_arn == "" }
  registry_arns = {
    for name, env in var.envs :
    name => env.registry_parameter_arn != "" ? env.registry_parameter_arn : try(aws_ssm_parameter.registry[name].arn, null)
  }

  # each env's own settings, named as in APP_ENVS; unset ones are left out,
  # so the shared ones apply
  env_entries = {
    for name, env in var.envs : name => merge(
      {
        name            = name
        dynamodbTable   = local.table_names[name]
        kmsTransitKeyId = env.kms_transit_key_arn
        registry        = local.registry_arns[name]
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
  app_envs = jsonencode({ envs = [for name in local.env_names : local.env_entries[name]] })

  # the APP_ variable each APP_ENVS setting stands for, as the app maps them
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
  env_environment = local.multi_env ? {
    APP_ENVS = try(aws_ssm_parameter.envs[0].arn, null)
    } : {
    for key, value in local.env_entries[local.env_names[0]] :
    local.env_setting_variables[key] => try(join(",", value), tostring(value))
  }

  # ----------------------------------------------------------- environment ---

  domain_enabled = local.enabled && var.domain_config.enabled
  public_url = (
    var.control_plane_config.public_url != "" ? trimsuffix(var.control_plane_config.public_url, "/") :
    var.domain_config.enabled ? "https://${var.domain_config.domain_name}" :
    try(aws_apigatewayv2_api.this[0].api_endpoint, "")
  )
  agent_audience = var.control_plane_config.agent_audience != "" ? var.control_plane_config.agent_audience : local.public_url

  tick_enabled  = local.enabled && var.tick_config.enabled
  tick_interval = "${regex("^rate\\(([0-9]+) minutes?\\)$", var.tick_config.schedule_expression)[0]}m"

  # the env's own settings replace the shared ones, and empty ones are left
  # out, so the app applies its defaults
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
      APP_TICK_INTERVAL              = var.tick_config.enabled ? local.tick_interval : ""
    },
    # secrets as ssm parameter arns; an env's own admin token is in its
    # settings
    { for name, arn in local.secret_arns : name => arn if startswith(name, "APP_") },
    local.env_environment,
  )

  # settings in ssm are read when an instance starts, so a change to a
  # parameter the module manages changes the function's configuration, which
  # replaces its instances. registries are read again while it runs.
  config_revision = substr(sha256(jsonencode({
    secrets = { for name, param in aws_ssm_parameter.secret : name => param.version }
    envs    = [for param in aws_ssm_parameter.envs : param.version]
  })), 0, 16)

  lambda_environment = merge(
    { for name, value in local.app_environment : name => value if value != null && value != "" },
    { SEALER_CONFIG_REVISION = local.config_revision },
    var.lambda_environment_variables,
  )

  # every parameter the function reads: the module's, and those given as arns
  managed_parameter_count = length(local.stored_secret_names) + length(local.inline_registries) + (local.multi_env ? 1 : 0)
  managed_parameter_arns = concat(
    [for param in aws_ssm_parameter.secret : param.arn],
    [for param in aws_ssm_parameter.registry : param.arn],
    [for param in aws_ssm_parameter.envs : param.arn],
  )
  given_parameter_arns = distinct(concat(
    values(local.given_secret_arns),
    [for env in var.envs : env.registry_parameter_arn if env.registry_parameter_arn != ""],
    var.ssm_parameter_arns,
  ))
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

# ================================================================ dynamodb ===

# one table per env; each holds its env's escrowed sealing keys

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

# ===================================================================== ssm ===

resource "random_password" "secret" {
  for_each = local.enabled ? local.generated_secret_names : toset([])

  length  = 64
  special = false
}

resource "aws_ssm_parameter" "secret" {
  for_each = local.enabled ? local.stored_secret_names : toset([])

  name        = "${local.ssm_parameter_prefix}${each.key}"
  description = "${each.key} of ${module.this.id}"
  type        = "SecureString"
  value       = local.stored_secret_values[each.key]
  key_id      = var.ssm_config.kms_key_arn != "" ? var.ssm_config.kms_key_arn : null

  tags = module.this.tags
}

# the function reads each registry again about once a minute, so a change
# needs no restart
resource "aws_ssm_parameter" "registry" {
  for_each = local.enabled ? local.inline_registries : {}

  name           = "${local.ssm_parameter_prefix}envs/${each.key}/registry"
  description    = "Agent registry of the ${each.key} env of ${module.this.id}"
  type           = "String"
  tier           = length(each.value) > 4096 ? "Advanced" : "Standard"
  insecure_value = each.value

  tags = module.this.tags
}

# APP_ENVS lives in ssm, where it has room to grow past the 4 KB that the
# function's environment holds in all
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

data "buildkit_context" "app" {
  count = local.enabled ? 1 : 0

  path = abspath("${path.module}/assets/lambda-function")
}

# the release's lambda zip for the function's architecture, checked against
# the release's checksums
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

resource "aws_lambda_function" "this" {
  count = local.enabled ? 1 : 0

  function_name                  = module.this.id
  description                    = "k8s-sealed-secrets-sealer control plane ${var.app_version}"
  role                           = aws_iam_role.this[0].arn
  handler                        = "bootstrap"
  runtime                        = "provided.al2023"
  memory_size                    = var.lambda_config.memory_size
  timeout                        = var.lambda_config.timeout
  reserved_concurrent_executions = var.lambda_config.reserved_concurrent_executions
  architectures                  = [var.lambda_config.architecture]

  filename         = buildkit_artifact.app[0].artifact_path
  source_code_hash = buildkit_artifact.app[0].artifact_sha256

  environment {
    variables = local.lambda_environment
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
      error_message = "admin_token_config.env_tokens names an env that envs does not."
    }

    precondition {
      condition = alltrue([
        for name, env in var.envs : !env.admin_token_key_changes || local.admin_enabled || contains(local.env_token_names, name)
      ])
      error_message = "An env with admin_token_key_changes needs an admin token: enable admin_token_config, or give the env one in admin_token_config.env_tokens."
    }

    precondition {
      condition     = length(distinct(values(local.table_names))) == length(local.table_names)
      error_message = "Each env needs its own DynamoDB table."
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_iam_role_policy.this,
    aws_dynamodb_table.this,
    aws_ssm_parameter.registry,
  ]

  tags = module.this.tags
}

resource "aws_cloudwatch_log_group" "lambda" {
  count = local.enabled ? 1 : 0

  name              = "/aws/lambda/${module.this.id}"
  retention_in_days = var.lambda_log_retention_days
  tags              = module.this.tags
}

# --------------------------------------------------------------------- iam ---

resource "aws_iam_role" "this" {
  count = local.enabled ? 1 : 0

  name        = module.this.id
  description = "Role of the ${module.this.id} Lambda function"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow"
      Principal = { "Service" : "lambda.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = module.this.tags
}

data "aws_iam_policy_document" "this" {
  count = local.enabled ? 1 : 0

  statement {
    sid    = "CloudWatchLogsAccess"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.lambda[0].arn}:*"]
  }

  # every call the app's store makes; a transaction (TransactWriteItems) is
  # checked part by part, as a put, update, delete or ConditionCheckItem
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
    resources = [for name in local.env_names : local.table_arns[name]]
  }

  # dynamodb uses a table's customer managed key on the caller's behalf
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

  # values are encrypted for an agent under its env's transit key, with the
  # env in the encryption context, as its key policy also requires
  dynamic "statement" {
    for_each = local.env_names

    content {
      sid       = "TransitKey${index(local.env_names, statement.value)}"
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
    for_each = local.managed_parameter_count > 0 ? [1] : []

    content {
      sid       = "ReadParameters"
      effect    = "Allow"
      actions   = ["ssm:GetParameter"]
      resources = local.managed_parameter_arns
    }
  }

  dynamic "statement" {
    for_each = length(local.given_parameter_arns) > 0 ? [1] : []

    content {
      sid       = "ReadGivenParameters"
      effect    = "Allow"
      actions   = ["ssm:GetParameter"]
      resources = local.given_parameter_arns
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

  # what lambda needs to attach the function to the vpc
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

resource "aws_iam_role_policy" "this" {
  count = local.enabled ? 1 : 0

  name   = module.this.id
  role   = aws_iam_role.this[0].id
  policy = data.aws_iam_policy_document.this[0].json
}

# ============================================================= api gateway ===

# the $default route and stage pass every path to the function as is: the web
# UI at /, and the APIs under /api and /agent

resource "aws_apigatewayv2_api" "this" {
  count = local.enabled ? 1 : 0

  name          = module.this.id
  protocol_type = "HTTP"
  description   = "k8s-sealed-secrets-sealer control plane: web UI, user API and agent API"

  tags = module.this.tags
}

resource "aws_apigatewayv2_stage" "this" {
  count = local.enabled ? 1 : 0

  api_id      = aws_apigatewayv2_api.this[0].id
  name        = "$default"
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
  tags              = module.this.tags
}

# an http api gives up on the function after 30 seconds; agents' command polls
# end within 25
resource "aws_apigatewayv2_integration" "this" {
  count = local.enabled ? 1 : 0

  api_id                 = aws_apigatewayv2_api.this[0].id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.this[0].invoke_arn
  payload_format_version = "2.0"
  timeout_milliseconds   = 30000
}

resource "aws_apigatewayv2_route" "default" {
  count = local.enabled ? 1 : 0

  api_id    = aws_apigatewayv2_api.this[0].id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.this[0].id}"
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

  zone_id = var.domain_config.route53_zone_id
  name    = var.domain_config.domain_name
  type    = "A"

  alias {
    name                   = aws_apigatewayv2_domain_name.this[0].domain_name_configuration[0].target_domain_name
    zone_id                = aws_apigatewayv2_domain_name.this[0].domain_name_configuration[0].hosted_zone_id
    evaluate_target_health = false
  }
}

# =============================================================== scheduler ===

# ticks advance reseal schedules and runs; the function ticks every env it
# serves until 10 seconds before its timeout

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
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow"
      Principal = { "Service" : "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.aws_account_id }
      }
    }]
  })

  tags = module.this.tags
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

resource "aws_iam_role_policy" "scheduler" {
  count = local.tick_enabled ? 1 : 0

  name   = "${module.this.id}-tick"
  role   = aws_iam_role.scheduler[0].id
  policy = data.aws_iam_policy_document.scheduler[0].json
}
