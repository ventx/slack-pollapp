################################################################################
# Layer
################################################################################
resource "null_resource" "layer_pip_install_docker" {
  triggers = {
    # always_run = "${timestamp()}"
    shell_hash = "${sha256(file("${local.lambda_base_path}/${local.lambda_name}/requirements.txt"))}"
  }

  provisioner "local-exec" {
    command = "docker run -v ${local.lambda_base_path}/${local.lambda_name}:/build -v ${local.tmp_path}:/target --entrypoint /bin/bash public.ecr.aws/lambda/${local.lambda_runtime}:${local.lambda_runtime_version} -c \"yum install -y zip; python3 -m pip install -r /build/requirements.txt -t /tmp/layer/python/lib/${local.lambda_runtime}${local.lambda_runtime_version}/site-packages/; cd /tmp/layer; zip /target/${local.lambda_name}_layer.zip -FSr .\""
  }
}

data "local_file" "layer" {
  depends_on = [null_resource.layer_pip_install_docker]
  filename   = "${local.tmp_path}/${local.lambda_name}_layer.zip"
}

resource "aws_lambda_layer_version" "layer" {
  layer_name = "${local.prefix}_${local.lambda_name}"
  compatible_runtimes = ["${local.lambda_runtime}${local.lambda_runtime_version}"]
  filename         = "${local.tmp_path}/${local.lambda_name}_layer.zip"
  source_code_hash = data.local_file.layer.content_base64sha256
}

################################################################################
# IAM
################################################################################
resource "aws_iam_role" "lambda" {
  name               = "${local.prefix}_${local.lambda_name}_lambda"
  assume_role_policy = file("${path.module}/lambda_iam_role.json")
}

resource "aws_iam_policy" "lambda" {
  name = "${local.prefix}_${local.lambda_name}_lambda"
  policy = templatefile("${path.module}/lambda_iam_policy_${local.lambda_name}.json", {
    dynamo_db_arn            = aws_dynamodb_table.pollapp.arn
    slack_secrets_secret_arn = aws_secretsmanager_secret.slack_secrets.arn
  })
}

resource "aws_iam_role_policy_attachment" "lambda" {
  policy_arn = aws_iam_policy.lambda.arn
  role       = aws_iam_role.lambda.name
}

resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_role" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaRole"
}


################################################################################
# Lambda
################################################################################
data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = "lambda/${local.lambda_name}"
  output_path = "${local.tmp_path}/${local.lambda_name}.zip"
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.prefix}_${local.lambda_name}"
  retention_in_days = 3
}

resource "aws_lambda_function" "lambda" {
  depends_on = [
    aws_cloudwatch_log_group.lambda
  ]
  function_name    = "${local.prefix}_${local.lambda_name}"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  role             = aws_iam_role.lambda.arn
  handler          = "${local.lambda_name}.handler"
  runtime          = "${local.lambda_runtime}${local.lambda_runtime_version}"
  timeout          = 30

  memory_size = local.lambda_memory

  layers = [aws_lambda_layer_version.layer.arn]

  environment {
    variables = {
      SLACK_SECRETS_SECRET_ID            = aws_secretsmanager_secret.slack_secrets.id
      DYNAMODB_TABLE_NAME                = aws_dynamodb_table.pollapp.name
    }
  }
}
