output "set_slack_secret_command" {
  value = "aws secretsmanager put-secret-value --secret-id ${local.slack_secret_name} --secret-string \"{\\\"SLACK_BOT_TOKEN\\\":\\\"<SLACK_BOT_TOKEN>\\\",\\\"SLACK_SIGNING_SECRET\\\":\\\"<SLACK_SIGNING_SECRET>\\\"}\" --region ${var.aws_region} --profile ${var.aws_profile}"
}

output "delete_slack_secret_command" {
  value = "aws secretsmanager delete-secret --secret-id ${local.slack_secret_name} --force-delete-without-recovery --region ${var.aws_region} --profile ${var.aws_profile}"
}

output "check_url_command" {
  value = "nslookup ${local.api_url}"
}

data "template_file" "app_manifest" {
  template = "${file("${path.module}/app-manifest.yaml")}"
  vars = {
    URL = "https://${local.api_url}/"
  }
}

output "app_manifest" {
  value = "${data.template_file.app_manifest.rendered}"
}