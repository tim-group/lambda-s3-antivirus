provider "aws" {
  region = "eu-west-1"
  version = "~> 2.70"
}

terraform {
  backend "s3" {
    bucket = "timgroup-terraform"
    key = "state/lambda-s3-antivirus.tfstate"
    region = "eu-west-2"
  }
}

data "aws_s3_bucket" "shared-timgroup-bucket" {
  bucket = "timgroup"
}

data "aws_s3_bucket_object" "lambda-source" {
  bucket = data.aws_s3_bucket.shared-timgroup-bucket.bucket
  key = "lambda/executable.zip"
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
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "virus-scanner-can-read-av-definitions" {
  role = aws_iam_role.virus-scanner.name
  policy_arn = "arn:aws:iam::662373364858:policy/ReadAVDefinitions"
}

resource "aws_iam_role_policy_attachment" "virus-scanner-can-access-attachment-buckets" {
  role = aws_iam_role.virus-scanner.name
  policy_arn = "arn:aws:iam::662373364858:policy/ReadAccessTotest+production-tim-idea-attachments"
}

resource "aws_iam_role_policy_attachment" "virus-scanner-can-tag-attachments" {
  role = aws_iam_role.virus-scanner.name
  policy_arn = "arn:aws:iam::662373364858:policy/PutObjectTaggingAccessTotest+production-tim-idea-attachments"
}

data "aws_iam_policy" "virus-scanner-cloudwatch-logs" {
  arn = "arn:aws:iam::662373364858:policy/service-role/AWSLambdaBasicExecutionRole-93717aa9-8772-43a1-ad52-b1241ac16c6d"
}

resource "aws_iam_role_policy_attachment" "virus-scanner-can-write-cloudwatch-logs" {
  role = aws_iam_role.virus-scanner.name
  policy_arn = data.aws_iam_policy.virus-scanner-cloudwatch-logs.arn
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
          StringNotEquals = {
            "aws:PrincipalARN" = aws_iam_role.virus-scanner.arn
          }
        }
        Effect = "Deny"
        Principal = "*"
        Resource = "${aws_s3_bucket.test-tim-idea-attachments.arn}/*"
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
  memory_size = 1536
//  s3_bucket = data.aws_s3_bucket_object.lambda-source.bucket
//  s3_key = data.aws_s3_bucket_object.lambda-source.key

  environment {
    variables = {
      PATH_TO_AV_DEFINITIONS = "lambda/av-definitions"
      CLAMAV_BUCKET_NAME = data.aws_s3_bucket.shared-timgroup-bucket.bucket
      SLACK_WEBHOOK_URL = var.slack_webhook_url
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.virus-scanner-can-write-cloudwatch-logs,
    aws_iam_role_policy_attachment.virus-scanner-can-access-attachment-buckets,
    aws_iam_role_policy_attachment.virus-scanner-can-read-av-definitions,
    aws_iam_role_policy_attachment.virus-scanner-can-tag-attachments,
  ]
}

resource "aws_s3_bucket_notification" "test-tim-idea-attachments" {
  bucket = aws_s3_bucket.test-tim-idea-attachments.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.virus-scanner.arn
    events = [
      "s3:ObjectCreated:*"]
  }
}

resource "aws_iam_role" "virus-definitions-update" {
  name = "virus-definitions-update"
  path = "/service-role/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "virus-definitions-update-can-write-av-definitions" {
  role = aws_iam_role.virus-definitions-update.name
  policy_arn = "arn:aws:iam::662373364858:policy/WriteAVDefinitions"
}

data "aws_iam_policy" "virus-definitions-update-cloudwatch-logs" {
  arn = "arn:aws:iam::662373364858:policy/service-role/AWSLambdaBasicExecutionRole-f7ee4824-a2f0-4c3a-8865-c99e94962e0e"
}

resource "aws_iam_role_policy_attachment" "virus-definitions-update-can-write-cloudwatch-logs" {
  role = aws_iam_role.virus-definitions-update.name
  policy_arn = data.aws_iam_policy.virus-definitions-update-cloudwatch-logs.arn
}

resource "aws_lambda_function" "virus-definitions-update" {
  function_name = "virus-defintions-update"
  runtime = "nodejs10.x"
  role = aws_iam_role.virus-definitions-update.arn
  handler = "download-definitions.lambdaHandleEvent"
  description = "Download clamav anti-virus database and deposit it in S3 for scanner to use"
  timeout = 180
  memory_size = 1024
  s3_bucket = data.aws_s3_bucket_object.lambda-source.bucket
  s3_key = data.aws_s3_bucket_object.lambda-source.key

  environment {
    variables = {
      PATH_TO_AV_DEFINITIONS = "lambda/av-definitions"
      CLAMAV_BUCKET_NAME = data.aws_s3_bucket.shared-timgroup-bucket.bucket
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.virus-definitions-update-can-write-cloudwatch-logs,
    aws_iam_role_policy_attachment.virus-definitions-update-can-write-av-definitions,
  ]
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
