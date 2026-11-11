# Plans the module with mocked providers: no AWS account, nothing downloaded.

mock_provider "aws" {
  override_during = plan

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }
  mock_data "aws_region" {
    defaults = {
      region = "us-east-2"
    }
  }
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111111111111"
    }
  }
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{}"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::111111111111:role/mock"
    }
  }
  mock_resource "aws_kms_key" {
    defaults = {
      arn    = "arn:aws:kms:us-east-2:111111111111:key/table-key"
      key_id = "table-key"
    }
  }
  mock_resource "aws_ssm_parameter" {
    defaults = {
      arn     = "arn:aws:ssm:us-east-2:111111111111:parameter/mock"
      version = 1
    }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-east-2:111111111111:log-group:mock"
    }
  }
  mock_resource "aws_apigatewayv2_api" {
    defaults = {
      api_endpoint  = "https://abc123.execute-api.us-east-2.amazonaws.com"
      execution_arn = "arn:aws:execute-api:us-east-2:111111111111:abc123"
    }
  }
  mock_resource "aws_lambda_function" {
    defaults = {
      arn        = "arn:aws:lambda:us-east-2:111111111111:function:sealer"
      invoke_arn = "arn:aws:apigateway:us-east-2:lambda:path/functions/sealer/invocations"
    }
  }
  mock_resource "aws_scheduler_schedule" {
    defaults = {
      arn = "arn:aws:scheduler:us-east-2:111111111111:schedule/default/sealer-tick"
    }
  }
}

mock_provider "buildkit" {
  override_during = plan

  mock_data "buildkit_context" {
    defaults = {
      digest = "sha256:context"
    }
  }
  mock_resource "buildkit_artifact" {
    defaults = {
      artifact_path   = "/work/dist/sealer/package.zip"
      artifact_sha256 = "package-sha256"
    }
  }
}

mock_provider "random" {
  override_during = plan

  mock_resource "random_password" {
    defaults = {
      result = "generated-secret-0123456789abcdef0123456789abcdef"
    }
  }
}


variables {
  name = "sealer"
  github_app_config = {
    org           = "acme"
    app_id        = "123456"
    private_key   = "-----BEGIN RSA PRIVATE KEY-----\nkey\n-----END RSA PRIVATE KEY-----"
    client_id     = "Iv23liexample"
    client_secret = "an-oauth-client-secret"
  }
  envs = {
    prod = {
      kms_transit_key_arn = "arn:aws:kms:us-east-2:333333333333:key/mrk-prod"
      registry            = "agents: [{id: prod-use1-blue}]\n"
    }
  }
}

run "defaults" {
  command = plan

  assert {
    condition = alltrue([
      aws_lambda_function.this[0].function_name == "sealer",
      aws_lambda_function.this[0].runtime == "provided.al2023",
      aws_lambda_function.this[0].handler == "bootstrap",
      aws_lambda_function.this[0].architectures[0] == "arm64",
      aws_lambda_function.this[0].timeout == 60,
      aws_lambda_function.this[0].memory_size == 256,
      aws_lambda_function.this[0].filename == "/work/dist/sealer/package.zip",
      aws_lambda_function.this[0].source_code_hash == "package-sha256",
      length(aws_lambda_function.this[0].vpc_config) == 0,
    ])
    error_message = "the function should run the release's arm64 bootstrap with a 60-second timeout"
  }

  assert {
    condition = alltrue([
      buildkit_artifact.app[0].target == "package",
      buildkit_artifact.app[0].artifact_src_path == "/tmp/package.zip",
      buildkit_artifact.app[0].artifact_dst_path == "./dist/sealer/package.zip",
      buildkit_artifact.app[0].build_args == tomap({ APP_VERSION = "v0.10.0", APP_REPO = "cruxstack/k8s-sealed-secrets-sealer", GOARCH = "arm64" }),
      buildkit_artifact.app[0].triggers == tomap({
        context          = "sha256:context"
        app_version      = "v0.10.0"
        app_repo         = "cruxstack/k8s-sealed-secrets-sealer"
        goarch           = "arm64"
        force_rebuild_id = ""
      }),
    ])
    error_message = "the package should be the default release's arm64 zip, at a path unique to the instance"
  }

  assert {
    condition = aws_lambda_function.this[0].environment[0].variables == tomap({
      APP_LOG_LEVEL                  = "info"
      APP_LOG_FORMAT                 = "json"
      APP_PUBLIC_URL                 = "https://abc123.execute-api.us-east-2.amazonaws.com"
      APP_GITHUB_ORG                 = "acme"
      APP_GITHUB_APP_ID              = "123456"
      APP_GITHUB_OAUTH_CLIENT_ID     = "Iv23liexample"
      APP_GITHUB_APP_PRIVATE_KEY     = "arn:aws:ssm:us-east-2:111111111111:parameter/mock"
      APP_GITHUB_OAUTH_CLIENT_SECRET = "arn:aws:ssm:us-east-2:111111111111:parameter/mock"
      APP_AGENT_SESSION_KEY          = "arn:aws:ssm:us-east-2:111111111111:parameter/mock"
      APP_USER_SESSION_KEY           = "arn:aws:ssm:us-east-2:111111111111:parameter/mock"
      APP_TICK_INTERVAL              = "1m"
      APP_ENV_NAME                   = "prod"
      APP_DYNAMODB_TABLE             = "sealer-prod"
      APP_KMS_TRANSIT_KEY_ID         = "arn:aws:kms:us-east-2:333333333333:key/mrk-prod"
      APP_REGISTRY                   = "arn:aws:ssm:us-east-2:111111111111:parameter/mock"
      SEALER_CONFIG_REVISION         = local.config_revision
    })
    error_message = "one env should use the single-env settings and secrets as parameter arns, with unset settings left out"
  }

  assert {
    condition = alltrue([
      toset(keys(aws_ssm_parameter.secret)) == toset(["APP_AGENT_SESSION_KEY", "APP_GITHUB_APP_PRIVATE_KEY", "APP_GITHUB_OAUTH_CLIENT_SECRET", "APP_USER_SESSION_KEY"]),
      alltrue([for p in aws_ssm_parameter.secret : p.type == "SecureString"]),
      aws_ssm_parameter.secret["APP_AGENT_SESSION_KEY"].name == "/sealer/APP_AGENT_SESSION_KEY",
      toset(keys(random_password.secret)) == toset(["APP_AGENT_SESSION_KEY", "APP_USER_SESSION_KEY"]),
      alltrue([for p in random_password.secret : p.length >= 32 && !p.special]),
      aws_ssm_parameter.registry["prod"].name == "/sealer/envs/prod/registry",
      aws_ssm_parameter.registry["prod"].type == "String",
      aws_ssm_parameter.registry["prod"].tier == "Standard",
      aws_ssm_parameter.registry["prod"].insecure_value == "agents: [{id: prod-use1-blue}]\n",
      length(aws_ssm_parameter.envs) == 0,
    ])
    error_message = "secrets should be secure strings under /<id>/ with the session keys generated, and the registry a string"
  }

  # sensitive values are checked apart, since terraform test cannot show them
  assert {
    condition = alltrue([
      nonsensitive(aws_ssm_parameter.secret["APP_AGENT_SESSION_KEY"].value) == "generated-secret-0123456789abcdef0123456789abcdef",
      nonsensitive(aws_ssm_parameter.secret["APP_GITHUB_OAUTH_CLIENT_SECRET"].value) == "an-oauth-client-secret",
    ])
    error_message = "the parameters should hold the generated and given secrets"
  }

  assert {
    condition = alltrue([
      aws_dynamodb_table.this["prod"].name == "sealer-prod",
      aws_dynamodb_table.this["prod"].billing_mode == "PAY_PER_REQUEST",
      aws_dynamodb_table.this["prod"].hash_key == "pk",
      aws_dynamodb_table.this["prod"].range_key == "sk",
      toset([for a in aws_dynamodb_table.this["prod"].attribute : "${a.name}:${a.type}"]) == toset(["pk:S", "sk:S"]),
      aws_dynamodb_table.this["prod"].ttl[0].attribute_name == "expires_at",
      aws_dynamodb_table.this["prod"].ttl[0].enabled,
      aws_dynamodb_table.this["prod"].point_in_time_recovery[0].enabled,
      aws_dynamodb_table.this["prod"].deletion_protection_enabled,
      aws_dynamodb_table.this["prod"].server_side_encryption[0].kms_key_arn == "arn:aws:kms:us-east-2:111111111111:key/table-key",
      aws_kms_key.dynamodb[0].enable_key_rotation,
      aws_kms_key.dynamodb[0].deletion_window_in_days == 30,
      aws_kms_alias.dynamodb[0].name == "alias/sealer-dynamodb",
    ])
    error_message = "the table should have pk/sk, ttl, pitr, deletion protection and the module's rotating key"
  }

  assert {
    condition = alltrue([
      aws_apigatewayv2_stage.this[0].name == "$default",
      aws_apigatewayv2_stage.this[0].auto_deploy,
      aws_apigatewayv2_stage.this[0].default_route_settings[0].throttling_burst_limit == 100,
      aws_apigatewayv2_stage.this[0].default_route_settings[0].throttling_rate_limit == 50,
      aws_apigatewayv2_route.default[0].route_key == "$default",
      aws_apigatewayv2_integration.this[0].payload_format_version == "2.0",
      aws_apigatewayv2_integration.this[0].timeout_milliseconds == 30000,
      length(aws_apigatewayv2_domain_name.this) == 0,
    ])
    error_message = "every path should reach the function through the $default route and stage"
  }

  assert {
    condition = alltrue([
      aws_scheduler_schedule.tick[0].name == "sealer-tick",
      aws_scheduler_schedule.tick[0].schedule_expression == "rate(1 minute)",
      aws_scheduler_schedule.tick[0].flexible_time_window[0].mode == "OFF",
      aws_scheduler_schedule.tick[0].target[0].arn == "arn:aws:lambda:us-east-2:111111111111:function:sealer",
      aws_scheduler_schedule.tick[0].target[0].input == "{\"sealer\":\"tick\"}",
      aws_scheduler_schedule.tick[0].target[0].role_arn == aws_iam_role.scheduler[0].arn,
      [for s in data.aws_iam_policy_document.scheduler[0].statement : [s.actions, s.resources]] == [
        [toset(["lambda:InvokeFunction"]), toset(["arn:aws:lambda:us-east-2:111111111111:function:sealer"])],
      ],
    ])
    error_message = "a schedule should tick every minute, with a role that may only invoke the function"
  }

  assert {
    condition = alltrue([
      output.url == "https://abc123.execute-api.us-east-2.amazonaws.com",
      output.agent_audience == "https://abc123.execute-api.us-east-2.amazonaws.com",
      output.oauth_callback_url == "https://abc123.execute-api.us-east-2.amazonaws.com/api/v1/auth/callback",
      output.dynamodb_tables.prod == { name = "sealer-prod", arn = "arn:aws:dynamodb:us-east-2:111111111111:table/sealer-prod" },
      output.dynamodb_kms_key_arn == "arn:aws:kms:us-east-2:111111111111:key/table-key",
      output.scheduler_schedule_arn == "arn:aws:scheduler:us-east-2:111111111111:schedule/default/sealer-tick",
      output.lambda_role_arn == "arn:aws:iam::111111111111:role/mock",
      output.api_gateway_domain_target == null,
    ])
    error_message = "the outputs should name the API's url and callback, the table and the schedule"
  }
}

run "iam_policy" {
  command = plan

  variables {
    envs = {
      dev = {
        kms_transit_key_arn = "arn:aws:kms:us-east-2:222222222222:key/mrk-dev"
        registry            = "agents: [{id: dev-use1-blue}]\n"
      }
      prod = {
        kms_transit_key_arn    = "arn:aws:kms:us-east-2:333333333333:key/mrk-prod"
        registry_parameter_arn = "arn:aws:ssm:us-east-2:111111111111:parameter/sealer/prod/registry"
        dynamodb_table = {
          name        = "sealer-prod-restored"
          kms_key_arn = "arn:aws:kms:us-east-2:111111111111:key/restored"
        }
      }
    }
    ssm_config         = { kms_key_arn = "arn:aws:kms:us-east-2:111111111111:key/ssm" }
    ssm_parameter_arns = ["arn:aws:ssm:us-east-2:111111111111:parameter/extra"]
  }

  assert {
    condition = { for s in data.aws_iam_policy_document.this[0].statement : s.sid => [s.actions, s.resources] } == {
      CloudWatchLogsAccess = [
        toset(["logs:CreateLogStream", "logs:PutLogEvents"]),
        toset(["arn:aws:logs:us-east-2:111111111111:log-group:mock:*"]),
      ]
      Tables = [
        toset([
          "dynamodb:BatchGetItem",
          "dynamodb:ConditionCheckItem",
          "dynamodb:DeleteItem",
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:Query",
          "dynamodb:UpdateItem",
        ]),
        toset([
          "arn:aws:dynamodb:us-east-2:111111111111:table/sealer-dev",
          "arn:aws:dynamodb:us-east-2:111111111111:table/sealer-prod-restored",
        ]),
      ]
      TableKeys = [
        toset(["kms:Decrypt"]),
        toset(["arn:aws:kms:us-east-2:111111111111:key/table-key", "arn:aws:kms:us-east-2:111111111111:key/restored"]),
      ]
      TransitKey0 = [toset(["kms:GenerateDataKey"]), toset(["arn:aws:kms:us-east-2:222222222222:key/mrk-dev"])]
      TransitKey1 = [toset(["kms:GenerateDataKey"]), toset(["arn:aws:kms:us-east-2:333333333333:key/mrk-prod"])]
      ReadParameters = [
        toset(["ssm:GetParameter"]),
        toset([
          "arn:aws:ssm:us-east-2:111111111111:parameter/mock",
          "arn:aws:ssm:us-east-2:111111111111:parameter/sealer/prod/registry",
          "arn:aws:ssm:us-east-2:111111111111:parameter/extra",
        ]),
      ]
      ParametersKey = [toset(["kms:Decrypt"]), toset(["arn:aws:kms:us-east-2:111111111111:key/ssm"])]
    }
    error_message = "the role should have exactly the logs, tables, keys and parameters the app uses"
  }

  assert {
    condition = {
      for s in data.aws_iam_policy_document.this[0].statement : s.sid => {
        for c in s.condition : c.variable => [c.test, c.values]
      } if length(s.condition) > 0
      } == {
      TableKeys     = { "kms:ViaService" = ["StringEquals", tolist(["dynamodb.us-east-2.amazonaws.com"])] }
      ParametersKey = { "kms:ViaService" = ["StringEquals", tolist(["ssm.us-east-2.amazonaws.com"])] }
      TransitKey0 = {
        "kms:EncryptionContext:env"     = ["StringEquals", tolist(["dev"])]
        "kms:EncryptionContext:purpose" = ["StringEquals", tolist(["seal"])]
      }
      TransitKey1 = {
        "kms:EncryptionContext:env"     = ["StringEquals", tolist(["prod"])]
        "kms:EncryptionContext:purpose" = ["StringEquals", tolist(["seal"])]
      }
    }
    error_message = "the keys should be usable only through their services, and each transit key only for its env's seals"
  }

  assert {
    condition = alltrue([
      alltrue([for s in data.aws_iam_policy_document.this[0].statement : s.effect == "Allow"]),
      jsondecode(aws_iam_role.this[0].assume_role_policy).Statement[0].Principal.Service == "lambda.amazonaws.com",
      jsondecode(aws_iam_role.scheduler[0].assume_role_policy).Statement[0].Principal.Service == "scheduler.amazonaws.com",
      jsondecode(aws_iam_role.scheduler[0].assume_role_policy).Statement[0].Condition.StringEquals["aws:SourceAccount"] == "111111111111",
      [for s in data.aws_iam_policy_document.dynamodb_key[0].statement : [s.actions, [for p in s.principals : p.identifiers]]] == [
        [toset(["kms:*"]), [toset(["arn:aws:iam::111111111111:root"])]],
      ],
      aws_ssm_parameter.secret["APP_AGENT_SESSION_KEY"].key_id == "arn:aws:kms:us-east-2:111111111111:key/ssm",
    ])
    error_message = "the roles should trust their services, the table key the account, and secrets use the given key"
  }
}

run "two_envs" {
  command = plan

  variables {
    envs = {
      prod = {
        kms_transit_key_arn     = "arn:aws:kms:us-east-2:333333333333:key/mrk-prod"
        registry                = "agents: [{id: prod-use1-blue}]\n"
        allowed_teams           = ["prod-sealers"]
        admin_token_key_changes = true
        env_annotation          = "example.com/env"
        discovery_file_globs    = ["deploy/*.yaml"]
        key_renew_period        = "2160h"
      }
      dev = {
        kms_transit_key_arn = "arn:aws:kms:us-east-1:222222222222:key/mrk-dev"
        registry            = "agents: [{id: dev-use1-blue}]\n"
        admin_teams         = []
      }
    }
    control_plane_config = {
      allowed_teams    = ["engineering"]
      admin_teams      = ["platform"]
      user_session_ttl = "4h"
      aws_sts_hosts    = ["sts.us-east-2.amazonaws.com", "sts.us-east-1.amazonaws.com"]
    }
    admin_token_config = {
      enabled    = true
      env_tokens = { prod = "" }
    }
  }

  assert {
    condition = jsondecode(aws_ssm_parameter.envs[0].insecure_value) == {
      envs = [
        {
          name            = "dev"
          dynamodbTable   = "sealer-dev"
          kmsTransitKeyId = "arn:aws:kms:us-east-1:222222222222:key/mrk-dev"
          registry        = "arn:aws:ssm:us-east-2:111111111111:parameter/mock"
          adminTeams      = []
        },
        {
          name                 = "prod"
          dynamodbTable        = "sealer-prod"
          kmsTransitKeyId      = "arn:aws:kms:us-east-2:333333333333:key/mrk-prod"
          registry             = "arn:aws:ssm:us-east-2:111111111111:parameter/mock"
          allowedTeams         = ["prod-sealers"]
          adminToken           = "arn:aws:ssm:us-east-2:111111111111:parameter/mock"
          adminTokenKeyChanges = true
          envAnnotation        = "example.com/env"
          discoveryFileGlobs   = ["deploy/*.yaml"]
          keyRenewPeriod       = "2160h"
        },
      ]
    }
    error_message = "APP_ENVS should list each env in name order, with only the settings it sets"
  }

  assert {
    condition = alltrue([
      aws_ssm_parameter.envs[0].name == "/sealer/APP_ENVS",
      aws_ssm_parameter.envs[0].type == "String",
      aws_ssm_parameter.envs[0].tier == "Standard",
      aws_lambda_function.this[0].environment[0].variables["APP_ENVS"] == "arn:aws:ssm:us-east-2:111111111111:parameter/mock",
      length(setintersection(keys(aws_lambda_function.this[0].environment[0].variables), [
        "APP_ENV_NAME", "APP_REGISTRY", "APP_REGISTRY_FILE", "APP_DYNAMODB_TABLE", "APP_KMS_TRANSIT_KEY_ID", "APP_ADMIN_TOKEN_KEY_CHANGES",
      ])) == 0,
      aws_lambda_function.this[0].environment[0].variables["APP_GITHUB_ALLOWED_TEAMS"] == "engineering",
      aws_lambda_function.this[0].environment[0].variables["APP_GITHUB_ADMIN_TEAMS"] == "platform",
      aws_lambda_function.this[0].environment[0].variables["APP_USER_SESSION_TTL"] == "4h",
      aws_lambda_function.this[0].environment[0].variables["APP_AWS_STS_HOSTS"] == "sts.us-east-2.amazonaws.com,sts.us-east-1.amazonaws.com",
      aws_lambda_function.this[0].environment[0].variables["APP_ADMIN_TOKEN"] == "arn:aws:ssm:us-east-2:111111111111:parameter/mock",
    ])
    error_message = "APP_ENVS should be in ssm, without the settings the app refuses beside it, and shared settings stay in the environment"
  }

  assert {
    condition = alltrue([
      toset(keys(aws_dynamodb_table.this)) == toset(["dev", "prod"]),
      toset(keys(aws_ssm_parameter.registry)) == toset(["dev", "prod"]),
      toset(keys(random_password.secret)) == toset(["APP_ADMIN_TOKEN", "APP_AGENT_SESSION_KEY", "APP_USER_SESSION_KEY", "envs/prod/admin-token"]),
      aws_ssm_parameter.secret["envs/prod/admin-token"].name == "/sealer/envs/prod/admin-token",
      toset(keys(output.ssm_parameter_arns)) == toset([
        "APP_ADMIN_TOKEN", "APP_AGENT_SESSION_KEY", "APP_ENVS", "APP_GITHUB_APP_PRIVATE_KEY", "APP_GITHUB_OAUTH_CLIENT_SECRET",
        "APP_USER_SESSION_KEY", "envs/dev/registry", "envs/prod/admin-token", "envs/prod/registry",
      ]),
    ])
    error_message = "each env should get its own table and registry, and prod its own admin token"
  }

  # sensitive values are checked apart, since terraform test cannot show them
  assert {
    condition = alltrue([
      nonsensitive(output.admin_token) == "generated-secret-0123456789abcdef0123456789abcdef",
      keys(nonsensitive(output.env_admin_tokens)) == ["prod"],
      nonsensitive(output.env_admin_tokens.prod) == "generated-secret-0123456789abcdef0123456789abcdef",
    ])
    error_message = "the outputs should hold the generated admin tokens"
  }
}

# single-Region keys work as multi-Region ones do, in any region
run "single_region_transit_keys" {
  command = plan

  variables {
    envs = {
      dev = {
        kms_transit_key_arn = "arn:aws:kms:us-east-1:222222222222:key/1234abcd-12ab-34cd-56ef-1234567890ab"
        registry            = "agents: [{id: dev-use1-blue}]\n"
      }
      prod = {
        kms_transit_key_arn = "arn:aws:kms:us-east-2:333333333333:key/5678abcd-56ab-78cd-90ef-1234567890ab"
        registry            = "agents: [{id: prod-use1-blue}]\n"
      }
    }
  }

  assert {
    condition = [for env in jsondecode(aws_ssm_parameter.envs[0].insecure_value).envs : env.kmsTransitKeyId] == [
      "arn:aws:kms:us-east-1:222222222222:key/1234abcd-12ab-34cd-56ef-1234567890ab",
      "arn:aws:kms:us-east-2:333333333333:key/5678abcd-56ab-78cd-90ef-1234567890ab",
    ]
    error_message = "each env should get its own single-Region transit key"
  }

  assert {
    condition = {
      for s in data.aws_iam_policy_document.this[0].statement : s.sid => s.resources if startswith(s.sid, "TransitKey")
      } == {
      TransitKey0 = toset(["arn:aws:kms:us-east-1:222222222222:key/1234abcd-12ab-34cd-56ef-1234567890ab"])
      TransitKey1 = toset(["arn:aws:kms:us-east-2:333333333333:key/5678abcd-56ab-78cd-90ef-1234567890ab"])
    }
    error_message = "the role should use each env's single-Region transit key, in its own region"
  }
}

run "existing_table" {
  command = plan

  variables {
    envs = {
      prod = {
        kms_transit_key_arn = "arn:aws:kms:us-east-2:333333333333:key/mrk-prod"
        registry            = "agents: [{id: prod-use1-blue}]\n"
        dynamodb_table      = { name = "sealer-prod-restored" }
      }
    }
  }

  assert {
    condition = alltrue([
      length(aws_dynamodb_table.this) == 0,
      length(aws_kms_key.dynamodb) == 0,
      aws_lambda_function.this[0].environment[0].variables["APP_DYNAMODB_TABLE"] == "sealer-prod-restored",
      output.dynamodb_tables.prod.arn == "arn:aws:dynamodb:us-east-2:111111111111:table/sealer-prod-restored",
      output.dynamodb_kms_key_arn == null,
      !contains([for s in data.aws_iam_policy_document.this[0].statement : s.sid], "TableKeys"),
    ])
    error_message = "an existing table should be used as is, with no table or key created"
  }
}

run "given_secrets" {
  command = plan

  variables {
    dynamodb_config = {
      kms_key_arn                 = "arn:aws:kms:us-east-2:111111111111:key/given"
      deletion_protection_enabled = false
    }
    session_keys_config = {
      agent_session_key = "an-agent-session-key-0123456789abcdef"
      user_session_key  = "a-user-session-key-0123456789abcdef"
    }
    admin_token_config = {
      enabled = true
      token   = "an-admin-token-0123456789abcdef0123"
    }
  }

  assert {
    condition = alltrue([
      length(aws_kms_key.dynamodb) == 0,
      aws_dynamodb_table.this["prod"].server_side_encryption[0].kms_key_arn == "arn:aws:kms:us-east-2:111111111111:key/given",
      !aws_dynamodb_table.this["prod"].deletion_protection_enabled,
      output.dynamodb_kms_key_arn == "arn:aws:kms:us-east-2:111111111111:key/given",
      length(random_password.secret) == 0,
    ])
    error_message = "a given table key should replace the module's, and nothing should be generated"
  }

  # sensitive values are checked apart, since terraform test cannot show them
  assert {
    condition = alltrue([
      nonsensitive(aws_ssm_parameter.secret["APP_AGENT_SESSION_KEY"].value) == "an-agent-session-key-0123456789abcdef",
      nonsensitive(aws_ssm_parameter.secret["APP_USER_SESSION_KEY"].value) == "a-user-session-key-0123456789abcdef",
      nonsensitive(output.admin_token) == "an-admin-token-0123456789abcdef0123",
    ])
    error_message = "given secrets should be stored as given"
  }
}

run "secret_arns" {
  command = plan

  variables {
    github_app_config = {
      org           = "acme"
      app_id        = "123456"
      private_key   = "arn:aws:ssm:us-east-2:111111111111:parameter/github/private-key"
      client_id     = "Iv23liexample"
      client_secret = "arn:aws:ssm:us-east-2:111111111111:parameter/github/client-secret"
    }
    session_keys_config = {
      agent_session_key = "arn:aws:ssm:us-east-2:111111111111:parameter/sealer/agent-session-key"
      user_session_key  = "arn:aws:ssm:us-east-2:111111111111:parameter/sealer/user-session-key"
    }
    admin_token_config = {
      env_tokens = { prod = "arn:aws:ssm:us-east-2:111111111111:parameter/sealer/prod/admin-token" }
    }
    envs = {
      prod = {
        kms_transit_key_arn     = "arn:aws:kms:us-east-2:333333333333:key/mrk-prod"
        registry_parameter_arn  = "arn:aws:ssm:us-east-2:111111111111:parameter/sealer/prod/registry"
        admin_token_key_changes = true
      }
    }
  }

  assert {
    condition = alltrue([
      length(aws_ssm_parameter.secret) == 0,
      length(aws_ssm_parameter.registry) == 0,
      length(random_password.secret) == 0,
      length(output.ssm_parameter_arns) == 0,
      length(nonsensitive(output.env_admin_tokens)) == 0,
    ])
    error_message = "secrets and registries given as parameter arns should not be stored again"
  }

  assert {
    condition = alltrue([
      aws_lambda_function.this[0].environment[0].variables["APP_GITHUB_APP_PRIVATE_KEY"] == "arn:aws:ssm:us-east-2:111111111111:parameter/github/private-key",
      aws_lambda_function.this[0].environment[0].variables["APP_GITHUB_OAUTH_CLIENT_SECRET"] == "arn:aws:ssm:us-east-2:111111111111:parameter/github/client-secret",
      aws_lambda_function.this[0].environment[0].variables["APP_AGENT_SESSION_KEY"] == "arn:aws:ssm:us-east-2:111111111111:parameter/sealer/agent-session-key",
      aws_lambda_function.this[0].environment[0].variables["APP_USER_SESSION_KEY"] == "arn:aws:ssm:us-east-2:111111111111:parameter/sealer/user-session-key",
      aws_lambda_function.this[0].environment[0].variables["APP_ADMIN_TOKEN"] == "arn:aws:ssm:us-east-2:111111111111:parameter/sealer/prod/admin-token",
      aws_lambda_function.this[0].environment[0].variables["APP_ADMIN_TOKEN_KEY_CHANGES"] == "true",
      aws_lambda_function.this[0].environment[0].variables["APP_REGISTRY"] == "arn:aws:ssm:us-east-2:111111111111:parameter/sealer/prod/registry",
    ])
    error_message = "the function should get the given arns, and one env's own admin token as APP_ADMIN_TOKEN"
  }

  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.this[0].statement :
      s.sid == "ReadParameters" && s.resources == toset([
        "arn:aws:ssm:us-east-2:111111111111:parameter/github/private-key",
        "arn:aws:ssm:us-east-2:111111111111:parameter/github/client-secret",
        "arn:aws:ssm:us-east-2:111111111111:parameter/sealer/agent-session-key",
        "arn:aws:ssm:us-east-2:111111111111:parameter/sealer/user-session-key",
        "arn:aws:ssm:us-east-2:111111111111:parameter/sealer/prod/admin-token",
        "arn:aws:ssm:us-east-2:111111111111:parameter/sealer/prod/registry",
      ])
    ])
    error_message = "the function should read exactly the given parameters"
  }
}

run "large_registry" {
  command = plan

  variables {
    envs = {
      prod = {
        kms_transit_key_arn = "arn:aws:kms:us-east-2:333333333333:key/mrk-prod"
        registry            = "agents: [{id: prod-use1-blue}]\n# ${join("", [for i in range(50) : "padding-0123456789-0123456789-0123456789-0123456789-0123456789-0123456789-0123456789"])}\n"
      }
    }
  }

  assert {
    condition     = aws_ssm_parameter.registry["prod"].tier == "Advanced"
    error_message = "a registry over 4 KB should go in an advanced parameter"
  }
}

run "domain_route53" {
  command = plan

  variables {
    domain_config = {
      enabled         = true
      domain_name     = "sealer.example.com"
      certificate_arn = "arn:aws:acm:us-east-2:111111111111:certificate/abc"
      route53_zone_id = "Z0123456789"
    }
  }

  assert {
    condition = alltrue([
      aws_apigatewayv2_domain_name.this[0].domain_name == "sealer.example.com",
      aws_apigatewayv2_domain_name.this[0].domain_name_configuration[0].certificate_arn == "arn:aws:acm:us-east-2:111111111111:certificate/abc",
      aws_apigatewayv2_domain_name.this[0].domain_name_configuration[0].endpoint_type == "REGIONAL",
      aws_apigatewayv2_domain_name.this[0].domain_name_configuration[0].security_policy == "TLS_1_2",
      length(aws_apigatewayv2_api_mapping.this) == 1,
      aws_route53_record.this[0].zone_id == "Z0123456789",
      aws_route53_record.this[0].name == "sealer.example.com",
      aws_route53_record.this[0].type == "A",
      aws_lambda_function.this[0].environment[0].variables["APP_PUBLIC_URL"] == "https://sealer.example.com",
      output.url == "https://sealer.example.com",
      output.agent_audience == "https://sealer.example.com",
      output.oauth_callback_url == "https://sealer.example.com/api/v1/auth/callback",
    ])
    error_message = "the custom domain should map to the stage, get its alias record, and be the public url"
  }
}

run "domain_only" {
  command = plan

  variables {
    domain_config = {
      enabled         = true
      domain_name     = "sealer.example.com"
      certificate_arn = "arn:aws:acm:us-east-2:111111111111:certificate/abc"
    }
  }

  assert {
    condition = alltrue([
      length(aws_apigatewayv2_api_mapping.this) == 1,
      length(aws_route53_record.this) == 0,
      output.api_gateway_domain_target != null,
    ])
    error_message = "without a zone, the domain should be mapped and its alias target output, with no record"
  }
}

run "public_url" {
  command = plan

  variables {
    control_plane_config = {
      public_url     = "https://sealer.example.com/"
      agent_audience = "https://sealer-agents.example.com"
    }
  }

  assert {
    condition = alltrue([
      aws_lambda_function.this[0].environment[0].variables["APP_PUBLIC_URL"] == "https://sealer.example.com",
      aws_lambda_function.this[0].environment[0].variables["APP_AGENT_AUDIENCE"] == "https://sealer-agents.example.com",
      output.url == "https://sealer.example.com",
      output.agent_audience == "https://sealer-agents.example.com",
    ])
    error_message = "a given public url and agent audience should replace the API's"
  }
}

run "ticks_off" {
  command = plan

  variables {
    tick_config = { enabled = false }
  }

  assert {
    condition = alltrue([
      length(aws_scheduler_schedule.tick) == 0,
      length(aws_iam_role.scheduler) == 0,
      !contains(keys(aws_lambda_function.this[0].environment[0].variables), "APP_TICK_INTERVAL"),
      output.scheduler_schedule_arn == null,
    ])
    error_message = "without ticks there should be no schedule, role or tick interval"
  }
}

run "tick_rate" {
  command = plan

  variables {
    tick_config = { schedule_expression = "rate(5 minutes)" }
  }

  assert {
    condition = alltrue([
      aws_scheduler_schedule.tick[0].schedule_expression == "rate(5 minutes)",
      aws_lambda_function.this[0].environment[0].variables["APP_TICK_INTERVAL"] == "5m",
    ])
    error_message = "the app's tick interval should match the schedule's rate"
  }
}

run "settings" {
  command = plan

  variables {
    app_version          = "v0.9.0"
    app_repo             = "example/k8s-sealed-secrets-sealer"
    app_force_rebuild_id = "2"
    log_level            = "debug"
    log_format           = "text"
    lambda_config = {
      architecture                   = "x86_64"
      memory_size                    = 512
      timeout                        = 90
      reserved_concurrent_executions = 20
    }
    lambda_log_retention_days = 90
    github_app_config = {
      org             = "acme"
      app_id          = "123456"
      private_key     = "-----BEGIN RSA PRIVATE KEY-----\nkey\n-----END RSA PRIVATE KEY-----"
      installation_id = "42"
      client_id       = "Iv23liexample"
      client_secret   = "an-oauth-client-secret"
      url             = "https://github.example.com"
      api_url         = "https://github.example.com/api/v3"
    }
    control_plane_config = {
      env_annotation       = "example.com/env"
      region_annotation    = "example.com/region"
      discovery_file_globs = ["*sealed*.yaml", "secrets/*.yaml"]
      key_renew_period     = "4380h"
    }
    api_gateway_config = {
      throttling_burst_limit = 20
      throttling_rate_limit  = 10
    }
    lambda_environment_variables = {
      APP_LOG_LEVEL = "warn"
      APP_EXTRA     = "1"
    }
  }

  assert {
    condition = alltrue([
      buildkit_artifact.app[0].build_args == tomap({ APP_VERSION = "v0.9.0", APP_REPO = "example/k8s-sealed-secrets-sealer", GOARCH = "amd64" }),
      buildkit_artifact.app[0].triggers["force_rebuild_id"] == "2",
      aws_lambda_function.this[0].architectures[0] == "x86_64",
      aws_lambda_function.this[0].memory_size == 512,
      aws_lambda_function.this[0].timeout == 90,
      aws_lambda_function.this[0].reserved_concurrent_executions == 20,
      aws_cloudwatch_log_group.lambda[0].retention_in_days == 90,
      aws_cloudwatch_log_group.api_gateway[0].retention_in_days == 90,
      aws_apigatewayv2_stage.this[0].default_route_settings[0].throttling_rate_limit == 10,
    ])
    error_message = "x86_64 should run the amd64 zip of the given release, with the given sizes and limits"
  }

  assert {
    condition = alltrue([
      aws_lambda_function.this[0].environment[0].variables["APP_LOG_LEVEL"] == "warn",
      aws_lambda_function.this[0].environment[0].variables["APP_LOG_FORMAT"] == "text",
      aws_lambda_function.this[0].environment[0].variables["APP_EXTRA"] == "1",
      aws_lambda_function.this[0].environment[0].variables["APP_GITHUB_APP_INSTALLATION_ID"] == "42",
      aws_lambda_function.this[0].environment[0].variables["APP_GITHUB_URL"] == "https://github.example.com",
      aws_lambda_function.this[0].environment[0].variables["APP_GITHUB_API_URL"] == "https://github.example.com/api/v3",
      aws_lambda_function.this[0].environment[0].variables["APP_ENV_ANNOTATION"] == "example.com/env",
      aws_lambda_function.this[0].environment[0].variables["APP_REGION_ANNOTATION"] == "example.com/region",
      aws_lambda_function.this[0].environment[0].variables["APP_DISCOVERY_FILE_GLOBS"] == "*sealed*.yaml,secrets/*.yaml",
      aws_lambda_function.this[0].environment[0].variables["APP_KEY_RENEW_PERIOD"] == "4380h",
    ])
    error_message = "settings should reach the function, and the given variables override the module's"
  }
}

run "env_overrides" {
  command = plan

  variables {
    control_plane_config = {
      allowed_teams  = ["engineering"]
      admin_teams    = ["platform"]
      env_annotation = "example.com/env"
    }
    envs = {
      prod = {
        kms_transit_key_arn = "arn:aws:kms:us-east-2:333333333333:key/mrk-prod"
        registry            = "agents: [{id: prod-use1-blue}]\n"
        allowed_teams       = []
        admin_teams         = ["prod-admins", "platform"]
        env_annotation      = "example.com/environment"
      }
    }
  }

  assert {
    condition = alltrue([
      !contains(keys(aws_lambda_function.this[0].environment[0].variables), "APP_GITHUB_ALLOWED_TEAMS"),
      aws_lambda_function.this[0].environment[0].variables["APP_GITHUB_ADMIN_TEAMS"] == "prod-admins,platform",
      aws_lambda_function.this[0].environment[0].variables["APP_ENV_ANNOTATION"] == "example.com/environment",
    ])
    error_message = "one env's own settings should replace the shared ones, an empty team list included"
  }
}

run "vpc" {
  command = plan

  variables {
    vpc_config = {
      subnet_ids         = ["subnet-1", "subnet-2"]
      security_group_ids = ["sg-1"]
    }
  }

  assert {
    condition = alltrue([
      aws_lambda_function.this[0].vpc_config[0].subnet_ids == toset(["subnet-1", "subnet-2"]),
      aws_lambda_function.this[0].vpc_config[0].security_group_ids == toset(["sg-1"]),
      anytrue([
        for s in data.aws_iam_policy_document.this[0].statement :
        s.sid == "VpcNetworkInterfaces" && contains(s.actions, "ec2:CreateNetworkInterface") && s.resources == toset(["*"])
      ]),
    ])
    error_message = "in a vpc, the function should get its subnets and the network interface permissions"
  }
}

run "disabled" {
  command = plan

  variables {
    enabled = false
  }

  assert {
    condition = alltrue([
      length(aws_lambda_function.this) == 0,
      length(buildkit_artifact.app) == 0,
      length(data.buildkit_context.app) == 0,
      length(aws_iam_role.this) == 0,
      length(aws_dynamodb_table.this) == 0,
      length(aws_kms_key.dynamodb) == 0,
      length(aws_ssm_parameter.secret) == 0,
      length(aws_ssm_parameter.registry) == 0,
      length(aws_ssm_parameter.envs) == 0,
      length(random_password.secret) == 0,
      length(aws_apigatewayv2_api.this) == 0,
      length(aws_cloudwatch_log_group.lambda) == 0,
      length(aws_scheduler_schedule.tick) == 0,
      length(aws_iam_role.scheduler) == 0,
    ])
    error_message = "a disabled module should create nothing"
  }

  assert {
    condition = alltrue([
      output.url == null,
      output.agent_audience == null,
      output.oauth_callback_url == null,
      output.dynamodb_tables == null,
      output.dynamodb_kms_key_arn == null,
      output.ssm_parameter_arns == null,
      output.lambda_function_arn == null,
      output.lambda_role_arn == null,
      output.api_gateway_id == null,
      output.api_gateway_domain_target == null,
      output.scheduler_schedule_arn == null,
    ])
    error_message = "a disabled module's outputs should be null"
  }

  # sensitive values are checked apart, since terraform test cannot show them
  assert {
    condition     = nonsensitive(output.admin_token) == null && nonsensitive(output.env_admin_tokens) == null
    error_message = "a disabled module's tokens should be null"
  }
}
