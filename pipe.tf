terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.34"
    }
  }

  required_version = ">= 1.5.0"
}

provider "aws" {
  profile = "uala-arg-playground_sandbox-dev-sso_ps_backend_dev"
  region  = "us-east-1"
}

# DynamoDB table
resource "aws_dynamodb_table" "PipeDemo" {
  name         = "PipeDemo"
  hash_key     = "id"
  billing_mode = "PAY_PER_REQUEST"

  attribute {
    name = "id"
    type = "S"
  }

  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"
}

## SQS queue
resource "aws_sqs_queue" "PipeDemoSQS" {
  name = "PipeDemoSQS"
}

# IAM role
resource "aws_iam_role" "pipe_iam_role" {
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = {
      Effect = "Allow"
      Action = "sts:AssumeRole"
      Principal = {
        Service = "pipes.amazonaws.com"
      }
    }
  })
}

# IAM Access policy
resource "aws_iam_policy" "dynamodb_access_policy" {
  depends_on = [aws_dynamodb_table.PipeDemo]

  name        = "PipeAccessPolicy"
  description = "Policy for accessing DynamoDB stream"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:DescribeStream",
          "dynamodb:GetRecords",
          "dynamodb:GetShardIterator",
          "dynamodb:ListStreams",
        ]
        Resource = aws_dynamodb_table.PipeDemo.stream_arn
      },
      {
        Effect = "Allow"
        Action = [
          "sqs:SendMessage"
        ],
        Resource = aws_sqs_queue.PipeDemoSQS.arn
      }
    ]
  })
}

# Attach policy to role
resource "aws_iam_role_policy_attachment" "dynamodb_access_attachment" {
  depends_on = [aws_iam_policy.dynamodb_access_policy, aws_iam_role.pipe_iam_role]

  policy_arn = aws_iam_policy.dynamodb_access_policy.arn
  role       = aws_iam_role.pipe_iam_role.name
}


# EventBridge Pipe
resource "aws_pipes_pipe" "PipeDemo" {
  name     = "PipeDemo"
  source   = aws_dynamodb_table.PipeDemo.stream_arn
  target   = aws_sqs_queue.PipeDemoSQS.arn
  role_arn = aws_iam_role.pipe_iam_role.arn

  source_parameters {
    dynamodb_stream_parameters {
      batch_size        = 1
      starting_position = "LATEST"
    }
    filter_criteria {
      filter {
        pattern = jsonencode({
          "eventName" : ["INSERT"]
        })
      }
    }
  }

  target_parameters {
    input_template = "{\"user_uuid\":\"<$.dynamodb.NewImage.id.S>\",\"operation_id\":\"<$.dynamodb.NewImage.operation_id.S>\"}"
  }

  depends_on = [
    aws_dynamodb_table.PipeDemo,
    aws_sqs_queue.PipeDemoSQS,
    aws_iam_role.pipe_iam_role,
    aws_iam_role_policy_attachment.dynamodb_access_attachment
  ]
}
