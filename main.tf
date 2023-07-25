provider "aws" {
  profile = var.aws_profile
  region  = var.aws_region
  default_tags {
    tags = var.tags
  }
}

provider "aws" {
  profile = var.aws_profile
  alias   = "us-east-1"
  region  = "us-east-1"
  default_tags {
    tags = var.tags
  }
}

terraform {
  required_version = ">= 1.2.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.6"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  prefix                = "${var.project}"
  tmp_path              = "${path.module}/tmp"
  api_url               = "${var.project}-api.${var.zone_name}"

  lambda_runtime         = "python"
  lambda_runtime_version = "3.9"
  lambda_base_path       = "${path.root}/lambda"
  lambda_name = "core"
  lambda_memory = 512

  slack_secret_name = "${local.prefix}_slack_secrets"
}

