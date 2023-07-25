resource "aws_secretsmanager_secret" "slack_secrets" {
  name = "${local.slack_secret_name}"
}