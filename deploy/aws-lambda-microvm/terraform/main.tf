terraform {
  required_version = ">= 1.3"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}

locals {
  account_id      = data.aws_caller_identity.current.account_id
  artifact_bucket = var.artifact_bucket != "" ? var.artifact_bucket : "${var.name_prefix}-artifacts-${local.account_id}"
}

# ---------------------------------------------------------------------------
# S3 artifact bucket — holds the image build context (Dockerfile + hooks zip).
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "artifacts" {
  bucket = local.artifact_bucket
  tags   = var.tags
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# Build role — assumed by Lambda while create-microvm-image builds the image.
# Trust MUST allow sts:AssumeRole AND sts:TagSession (build fails without the
# latter); aws:SourceAccount is confused-deputy hardening.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "build" {
  name               = "${var.name_prefix}-build"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "build" {
  statement {
    sid       = "ReadBuildArtifact"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.artifacts.arn}/*"]
  }
  statement {
    sid       = "CloudWatchLogsWrite"
    effect    = "Allow"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:${var.region}:${local.account_id}:log-group:/aws/lambda-microvms/*"]
  }
}

resource "aws_iam_role_policy" "build" {
  name   = "${var.name_prefix}-build"
  role   = aws_iam_role.build.id
  policy = data.aws_iam_policy_document.build.json
}

# ---------------------------------------------------------------------------
# Execution role — assumed by the running MicroVM. CW Logs + Bedrock (key-free
# model path: the in-VM runner reaches Bedrock through this role, so no model
# key enters the sandbox).
# ---------------------------------------------------------------------------
resource "aws_iam_role" "exec" {
  name               = "${var.name_prefix}-exec"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "exec" {
  statement {
    sid       = "CloudWatchLogsWrite"
    effect    = "Allow"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:${var.region}:${local.account_id}:log-group:/aws/lambda-microvms/*"]
  }
  statement {
    sid       = "BedrockInvokeForKeyFreeRunner"
    effect    = "Allow"
    actions   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "exec" {
  name   = "${var.name_prefix}-exec"
  role   = aws_iam_role.exec.id
  policy = data.aws_iam_policy_document.exec.json
}

# ---------------------------------------------------------------------------
# Operator/caller role — for the principal driving the control plane (server or
# operator). NOTE the IAM action namespace is `lambda:`, not `lambda-microvms:`.
# Trusts the account root for sandbox convenience; scope to a specific principal
# for production.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "operator_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:root"]
    }
  }
}

resource "aws_iam_role" "operator" {
  name               = "${var.name_prefix}-operator"
  assume_role_policy = data.aws_iam_policy_document.operator_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "operator" {
  statement {
    sid    = "LambdaMicroVMsControlPlane"
    effect = "Allow"
    actions = [
      "lambda:CreateMicrovmImage",
      "lambda:GetMicrovmImage",
      "lambda:GetMicrovmImageBuild",
      "lambda:GetMicrovmImageVersion",
      "lambda:ListMicrovmImages",
      "lambda:ListManagedMicrovmImageVersions",
      "lambda:DeleteMicrovmImage",
      "lambda:DeleteMicrovmImageVersion",
      "lambda:RunMicrovm",
      "lambda:GetMicrovm",
      "lambda:SuspendMicrovm",
      "lambda:ResumeMicrovm",
      "lambda:StopMicrovm",
      "lambda:CreateMicrovmAuthToken",
      "lambda:CreateMicrovmShellAuthToken",
      "lambda:TagResource",
      "lambda:UntagResource",
      "lambda:ListTags",
      "lambda:PassNetworkConnector",
    ]
    resources = ["*"]
  }
  statement {
    sid       = "PassMicroVMRoles"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.build.arn, aws_iam_role.exec.arn]
  }
}

resource "aws_iam_role_policy" "operator" {
  name   = "${var.name_prefix}-operator"
  role   = aws_iam_role.operator.id
  policy = data.aws_iam_policy_document.operator.json
}

# ---------------------------------------------------------------------------
# VPC egress network connector (optional).
#
# The connector lets the in-VM host dial back to the server over your VPC on a
# private address — no public 0.0.0.0/0 ingress, which is what accounts with an
# auto-remediation control (that strips 0.0.0.0/0 rules) require.
#
# Lambda MicroVMs / lambda-core is a new service; the AWS Terraform provider
# does not expose a native resource for network connectors yet. Until it does,
# we (1) create the connector-operator role natively (standard IAM) and (2)
# create the connector itself via the AWS CLI in a null_resource. Swap this for
# the native resource once the provider ships it.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "connector_operator_assume" {
  count = var.enable_vpc_egress_connector ? 1 : 0
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["network-connectors.lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "connector_operator" {
  count = var.enable_vpc_egress_connector ? 1 : 0
  statement {
    sid     = "CreateENI"
    effect  = "Allow"
    actions = ["ec2:CreateNetworkInterface"]
    resources = [
      "arn:aws:ec2:*:*:network-interface/*",
      "arn:aws:ec2:*:*:subnet/*",
      "arn:aws:ec2:*:*:security-group/*",
    ]
  }
  statement {
    sid       = "TagENI"
    effect    = "Allow"
    actions   = ["ec2:CreateTags"]
    resources = ["arn:aws:ec2:*:*:network-interface/*"]
    condition {
      test     = "StringEquals"
      variable = "ec2:ManagedResourceOperator"
      values   = ["network-connectors.lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "connector_operator" {
  count              = var.enable_vpc_egress_connector ? 1 : 0
  name               = "${var.name_prefix}-connector-operator"
  assume_role_policy = data.aws_iam_policy_document.connector_operator_assume[0].json
  tags               = var.tags
}

resource "aws_iam_role_policy" "connector_operator" {
  count  = var.enable_vpc_egress_connector ? 1 : 0
  name   = "${var.name_prefix}-connector-operator"
  role   = aws_iam_role.connector_operator[0].id
  policy = data.aws_iam_policy_document.connector_operator[0].json
}

resource "null_resource" "vpc_egress_connector" {
  count = var.enable_vpc_egress_connector ? 1 : 0

  triggers = {
    name            = "${var.name_prefix}-egress"
    subnets         = join(",", var.vpc_subnet_ids)
    security_groups = join(",", var.vpc_security_group_ids)
    operator_role   = aws_iam_role.connector_operator[0].arn
    region          = var.region
  }

  provisioner "local-exec" {
    command = <<-EOT
      aws lambda-core create-network-connector \
        --region ${var.region} \
        --name ${var.name_prefix}-egress \
        --operator-role ${aws_iam_role.connector_operator[0].arn} \
        --configuration '${jsonencode({
    VpcEgressConfiguration = {
      SubnetIds                      = var.vpc_subnet_ids
      SecurityGroupIds               = var.vpc_security_group_ids
      NetworkProtocol                = var.network_protocol
      AssociatedComputeResourceTypes = ["MicroVm"]
    }
})}'
    EOT
}

provisioner "local-exec" {
  when    = destroy
  command = "aws lambda-core delete-network-connector --region ${self.triggers.region} --name ${self.triggers.name} || true"
}
}
