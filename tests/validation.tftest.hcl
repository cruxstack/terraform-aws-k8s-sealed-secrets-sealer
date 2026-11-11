# Checks that the module refuses each invalid input.

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


# ===================================================================== app ===

run "rejects_no_envs" {
  command = plan

  variables {
    envs = {}
  }

  expect_failures = [var.envs]
}

run "rejects_env_name" {
  command = plan

  variables {
    envs = {
      Prod = {
        kms_transit_key_arn = "arn:aws:kms:us-east-2:333333333333:key/mrk-prod"
        registry            = "agents: [{id: prod-use1-blue}]\n"
      }
    }
  }

  expect_failures = [var.envs]
}

run "rejects_reserved_env_name" {
  command = plan

  variables {
    envs = {
      secrets = {
        kms_transit_key_arn = "arn:aws:kms:us-east-2:333333333333:key/mrk-prod"
        registry            = "agents: [{id: prod-use1-blue}]\n"
      }
    }
  }

  expect_failures = [var.envs]
}

run "rejects_transit_key_alias" {
  command = plan

  variables {
    envs = {
      prod = {
        kms_transit_key_arn = "arn:aws:kms:us-east-2:333333333333:alias/prod-transit"
        registry            = "agents: [{id: prod-use1-blue}]\n"
      }
    }
  }

  expect_failures = [var.envs]
}

run "rejects_shared_transit_key" {
  command = plan

  variables {
    envs = {
      dev = {
        kms_transit_key_arn = "arn:aws:kms:us-east-1:333333333333:key/mrk-prod"
        registry            = "agents: [{id: prod-use1-blue}]\n"
      }
      prod = {
        kms_transit_key_arn = "arn:aws:kms:us-east-2:333333333333:key/mrk-prod"
        registry            = "agents: [{id: prod-use1-blue}]\n"
      }
    }
  }

  expect_failures = [var.envs]
}

run "rejects_two_registries" {
  command = plan

  variables {
    envs = {
      prod = {
        kms_transit_key_arn    = "arn:aws:kms:us-east-2:333333333333:key/mrk-prod"
        registry               = "agents: [{id: prod-use1-blue}]\n"
        registry_parameter_arn = "arn:aws:ssm:us-east-2:111111111111:parameter/sealer/prod/registry"
      }
    }
  }

  expect_failures = [var.envs]
}

run "rejects_no_registry" {
  command = plan

  variables {
    envs = {
      prod = {
        kms_transit_key_arn = "arn:aws:kms:us-east-2:333333333333:key/mrk-prod"
      }
    }
  }

  expect_failures = [var.envs]
}

run "rejects_registry_not_yaml" {
  command = plan

  variables {
    envs = {
      prod = {
        kms_transit_key_arn = "arn:aws:kms:us-east-2:333333333333:key/mrk-prod"
        registry            = "agents: [\n"
      }
    }
  }

  expect_failures = [var.envs]
}

run "rejects_empty_registry" {
  command = plan

  variables {
    envs = {
      prod = {
        kms_transit_key_arn = "arn:aws:kms:us-east-2:333333333333:key/mrk-prod"
        registry            = "agents: []\n"
      }
    }
  }

  expect_failures = [var.envs]
}

run "rejects_large_registry" {
  command = plan

  variables {
    envs = {
      prod = {
        kms_transit_key_arn = "arn:aws:kms:us-east-2:333333333333:key/mrk-prod"
        registry            = "agents: [{id: prod-use1-blue}]\n# ${join("", [for i in range(9) : format("%01000d", 0)])}"
      }
    }
  }

  expect_failures = [var.envs]
}

run "rejects_registry_name" {
  command = plan

  variables {
    envs = {
      prod = {
        kms_transit_key_arn    = "arn:aws:kms:us-east-2:333333333333:key/mrk-prod"
        registry_parameter_arn = "/sealer/prod/registry"
      }
    }
  }

  expect_failures = [var.envs]
}

run "rejects_table_key_alias" {
  command = plan

  variables {
    envs = {
      prod = {
        kms_transit_key_arn = "arn:aws:kms:us-east-2:333333333333:key/mrk-prod"
        registry            = "agents: [{id: prod-use1-blue}]\n"
        dynamodb_table      = { name = "sealer-prod", kms_key_arn = "alias/aws/dynamodb" }
      }
    }
  }

  expect_failures = [var.envs]
}

run "rejects_env_annotation" {
  command = plan

  variables {
    envs = {
      prod = {
        kms_transit_key_arn = "arn:aws:kms:us-east-2:333333333333:key/mrk-prod"
        registry            = "agents: [{id: prod-use1-blue}]\n"
        env_annotation      = "example.com/env/name"
      }
    }
  }

  expect_failures = [var.envs]
}

run "rejects_renew_period" {
  command = plan

  variables {
    envs = {
      prod = {
        kms_transit_key_arn = "arn:aws:kms:us-east-2:333333333333:key/mrk-prod"
        registry            = "agents: [{id: prod-use1-blue}]\n"
        key_renew_period    = "30 days"
      }
    }
  }

  expect_failures = [var.envs]
}

run "rejects_github_org" {
  command = plan

  variables {
    github_app_config = {
      org           = "acme/inc"
      app_id        = "123456"
      private_key   = "-----BEGIN RSA PRIVATE KEY-----\nkey\n-----END RSA PRIVATE KEY-----"
      client_id     = "Iv23liexample"
      client_secret = "an-oauth-client-secret"
    }
  }

  expect_failures = [var.github_app_config]
}

run "rejects_github_app_id" {
  command = plan

  variables {
    github_app_config = {
      org           = "acme"
      app_id        = "sealer"
      private_key   = "-----BEGIN RSA PRIVATE KEY-----\nkey\n-----END RSA PRIVATE KEY-----"
      client_id     = "Iv23liexample"
      client_secret = "an-oauth-client-secret"
    }
  }

  expect_failures = [var.github_app_config]
}

run "rejects_github_private_key" {
  command = plan

  variables {
    github_app_config = {
      org           = "acme"
      app_id        = "123456"
      private_key   = "not a key"
      client_id     = "Iv23liexample"
      client_secret = "an-oauth-client-secret"
    }
  }

  expect_failures = [var.github_app_config]
}

run "rejects_github_client_secret" {
  command = plan

  variables {
    github_app_config = {
      org           = "acme"
      app_id        = "123456"
      private_key   = "-----BEGIN RSA PRIVATE KEY-----\nkey\n-----END RSA PRIVATE KEY-----"
      client_id     = "Iv23liexample"
      client_secret = ""
    }
  }

  expect_failures = [var.github_app_config]
}

run "rejects_github_url" {
  command = plan

  variables {
    github_app_config = {
      org           = "acme"
      app_id        = "123456"
      private_key   = "-----BEGIN RSA PRIVATE KEY-----\nkey\n-----END RSA PRIVATE KEY-----"
      client_id     = "Iv23liexample"
      client_secret = "an-oauth-client-secret"
      url           = "http://github.example.com"
    }
  }

  expect_failures = [var.github_app_config]
}

run "rejects_session_ttl" {
  command = plan

  variables {
    control_plane_config = { user_session_ttl = "8 hours" }
  }

  expect_failures = [var.control_plane_config]
}

run "rejects_public_url_path" {
  command = plan

  variables {
    control_plane_config = { public_url = "https://example.com/sealer" }
  }

  expect_failures = [var.control_plane_config]
}

run "rejects_agent_audience" {
  command = plan

  variables {
    control_plane_config = { agent_audience = "sealer.example.com" }
  }

  expect_failures = [var.control_plane_config]
}

run "rejects_sts_host_url" {
  command = plan

  variables {
    control_plane_config = { aws_sts_hosts = ["https://sts.us-east-2.amazonaws.com"] }
  }

  expect_failures = [var.control_plane_config]
}

run "rejects_shared_annotation" {
  command = plan

  variables {
    control_plane_config = { region_annotation = "-region" }
  }

  expect_failures = [var.control_plane_config]
}

# ================================================================ dynamodb ===

run "rejects_dynamodb_key_alias" {
  command = plan

  variables {
    dynamodb_config = { kms_key_arn = "alias/sealer" }
  }

  expect_failures = [var.dynamodb_config]
}

# ===================================================================== ssm ===

run "rejects_short_session_key" {
  command = plan

  variables {
    session_keys_config = { user_session_key = "short" }
  }

  expect_failures = [var.session_keys_config]
}

run "rejects_short_admin_token" {
  command = plan

  variables {
    admin_token_config = {
      enabled    = true
      env_tokens = { prod = "short" }
    }
  }

  expect_failures = [var.admin_token_config]
}

run "rejects_ssm_prefix" {
  command = plan

  variables {
    ssm_config = { parameter_prefix = "sealer" }
  }

  expect_failures = [var.ssm_config]
}

run "rejects_ssm_key_alias" {
  command = plan

  variables {
    ssm_config = { kms_key_arn = "alias/sealer" }
  }

  expect_failures = [var.ssm_config]
}

# ================================================================== lambda ===

run "rejects_app_version" {
  command = plan

  variables {
    app_version = "main"
  }

  expect_failures = [var.app_version]
}

run "rejects_app_repo" {
  command = plan

  variables {
    app_repo = "https://github.com/cruxstack/k8s-sealed-secrets-sealer.git"
  }

  expect_failures = [var.app_repo]
}

run "rejects_log_level" {
  command = plan

  variables {
    log_level = "trace"
  }

  expect_failures = [var.log_level]
}

run "rejects_log_format" {
  command = plan

  variables {
    log_format = "yaml"
  }

  expect_failures = [var.log_format]
}

run "rejects_short_timeout" {
  command = plan

  variables {
    lambda_config = { timeout = 30 }
  }

  expect_failures = [var.lambda_config]
}

run "rejects_unknown_token_env" {
  command = plan

  variables {
    admin_token_config = {
      env_tokens = { staging = "" }
    }
  }

  expect_failures = [aws_lambda_function.this]
}

run "rejects_key_changes_without_token" {
  command = plan

  variables {
    envs = {
      prod = {
        kms_transit_key_arn     = "arn:aws:kms:us-east-2:333333333333:key/mrk-prod"
        registry                = "agents: [{id: prod-use1-blue}]\n"
        admin_token_key_changes = true
      }
    }
  }

  expect_failures = [aws_lambda_function.this]
}

run "rejects_shared_table" {
  command = plan

  variables {
    envs = {
      dev = {
        kms_transit_key_arn = "arn:aws:kms:us-east-2:222222222222:key/mrk-dev"
        registry            = "agents: [{id: prod-use1-blue}]\n"
        dynamodb_table      = { name = "sealer-prod" }
      }
      prod = {
        kms_transit_key_arn = "arn:aws:kms:us-east-2:333333333333:key/mrk-prod"
        registry            = "agents: [{id: prod-use1-blue}]\n"
      }
    }
  }

  expect_failures = [aws_lambda_function.this]
}

# ----------------------------------------------------------- custom domain ---

run "rejects_domain_without_certificate" {
  command = plan

  variables {
    domain_config = {
      enabled     = true
      domain_name = "sealer.example.com"
    }
  }

  expect_failures = [var.domain_config]
}

# =============================================================== scheduler ===

run "rejects_tick_cron" {
  command = plan

  variables {
    tick_config = { schedule_expression = "cron(* * * * ? *)" }
  }

  expect_failures = [var.tick_config]
}

run "rejects_tick_one_minutes" {
  command = plan

  variables {
    tick_config = { schedule_expression = "rate(1 minutes)" }
  }

  expect_failures = [var.tick_config]
}

run "rejects_tick_over_10_minutes" {
  command = plan

  variables {
    tick_config = { schedule_expression = "rate(15 minutes)" }
  }

  expect_failures = [var.tick_config]
}
