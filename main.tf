provider "aws" {
  region = "eu-west-1"
  version = "~> 2.70"
}

data "aws_canonical_user_id" "current" { }

data "aws_s3_bucket" "shared-timgroup-bucket" {
  bucket = "timgroup"
}

resource "aws_s3_bucket" "test-tim-idea-attachments" {
  bucket = "test-tim-idea-attachments"
  acl = "private"

  lifecycle_rule {
    id = "remove files within 4 days"
    enabled = true
    abort_incomplete_multipart_upload_days = 7

    expiration {
      days = 2

    }
    noncurrent_version_expiration {
      days = 2
    }
  }

  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm = "AES256"
      }
    }
  }
}

resource "aws_iam_role" "virus-scanner" {
  name = "virus-scanner"
  path = "/service-role/"
  assume_role_policy = <<EOF
{
 "Version": "2012-10-17",
 "Statement": [
  {
   "Action": "sts:AssumeRole",
   "Effect": "Allow",
   "Principal": { "Service": "lambda.amazonaws.com" }
  }
 ]
}
EOF
}

resource "aws_s3_bucket_policy" "test-tim-idea-attachments" {
  bucket = "test-tim-idea-attachments"

  policy = jsonencode({
    Version = "2012-10-17"
    Id = "OY and CI only"
    Statement = [
      {
        Action = "s3:*"
        Condition = {
          NotIpAddress = {
            "aws:SourceIp" = [
              "45.75.195.64/27",
              "45.75.195.96/27",
              "31.221.52.150/32",
              "31.221.7.162/32",
            ]
          }
          StringNotEquals = { "aws:PrincipalARN" = aws_iam_role.virus-scanner.arn }
        }
        Effect = "Deny"
        Principal = "*"
        Resource = "arn:aws:s3:::test-tim-idea-attachments/*"
        Sid = "OY, CI, and Office Only"
      }
    ]
  })
}

resource "aws_lambda_function" "virus-scanner" {
  function_name = "virus-scanner"
  runtime = "nodejs10.x"
  role = aws_iam_role.virus-scanner.arn
  handler = "antivirus.lambdaHandleEvent"
  description = "Scan an S3 for viruses and update its tags to indicate the result"
  timeout = 180
  memory_size = 1024

  environment {
    variables = {
      PATH_TO_AV_DEFINITIONS = "lambda/av-definitions"
      CLAMAV_BUCKET_NAME = data.aws_s3_bucket.shared-timgroup-bucket.bucket
      SLACK_WEBHOOK_URL = var.slack_webhook_url
    }
  }
}

resource "aws_s3_bucket_notification" "test-tim-idea-attachments" {
  bucket = aws_s3_bucket.test-tim-idea-attachments.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.virus-scanner.arn
    events = ["s3:ObjectCreated:*"]
  }
}

resource "aws_iam_role" "virus-definitions-update" {
  name = "virus-definitions-update"
  path = "/service-role/"
  assume_role_policy = <<EOF
{
 "Version": "2012-10-17",
 "Statement": [
  {
   "Action": "sts:AssumeRole",
   "Effect": "Allow",
   "Principal": { "Service": "lambda.amazonaws.com" }
  }
 ]
}
EOF
}

resource "aws_lambda_function" "virus-definitions-update" {
  function_name = "virus-defintions-update"
  runtime = "nodejs10.x"
  role = aws_iam_role.virus-definitions-update.arn
  handler = "download-definitions.lambdaHandleEvent"
  description = "Download clamav anti-virus database and deposit it in S3 for scanner to use"
  timeout = 180
  memory_size = 1024

  environment {
    variables = {
      PATH_TO_AV_DEFINITIONS = "lambda/av-definitions"
      CLAMAV_BUCKET_NAME = data.aws_s3_bucket.shared-timgroup-bucket.bucket
    }
  }
}

resource "aws_cloudwatch_event_rule" "av-definitions-update" {
  name = "av-definitions-update"
  description = "Update the ClamAV virus definitions stored in S3"
  schedule_expression = "cron(0 */6 * * ? *)"
}

resource "aws_cloudwatch_event_target" "av-definitions-update" {
  rule = aws_cloudwatch_event_rule.av-definitions-update.name
  arn = aws_lambda_function.virus-definitions-update.arn
}

resource "aws_lambda_permission" "allow-cloudwatch-av-definitions-update" {
  action = "lambda:InvokeFunction"
  function_name = aws_lambda_function.virus-definitions-update.arn
  principal = "events.amazonaws.com"
  source_arn = aws_cloudwatch_event_rule.av-definitions-update.arn
}

output "virus-scanner" {
  value = aws_lambda_function.virus-scanner.arn
}

output "virus-definitions-update" {
  value = aws_lambda_function.virus-definitions-update.arn
}

