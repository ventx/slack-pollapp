################################################################################
# Record
################################################################################
data "aws_route53_zone" "pollapp" {
  name = var.zone_name
}

resource "aws_route53_record" "pollapp_api" {
  name    = local.api_url
  type    = "A"
  zone_id = data.aws_route53_zone.pollapp.id

  alias {
    evaluate_target_health = false
    name                   = aws_api_gateway_domain_name.pollapp.cloudfront_domain_name
    zone_id                = aws_api_gateway_domain_name.pollapp.cloudfront_zone_id
  }
}


################################################################################
# API Gateway
################################################################################
resource "aws_api_gateway_rest_api" "pollapp" {
  name = "${local.prefix}_api"
}

resource "aws_api_gateway_domain_name" "pollapp" {
  depends_on = [
    aws_acm_certificate_validation.pollapp_api
  ]
  domain_name     = local.api_url
  certificate_arn = aws_acm_certificate.pollapp_api.arn
}

resource "aws_api_gateway_base_path_mapping" "domain_mapping" {
  api_id      = aws_api_gateway_rest_api.pollapp.id
  domain_name = aws_api_gateway_domain_name.pollapp.domain_name
  stage_name  = aws_api_gateway_deployment.pollapp.stage_name
}

resource "aws_api_gateway_deployment" "pollapp" {
  depends_on = [
    aws_api_gateway_integration.pollapp,
    aws_api_gateway_method.pollapp
  ]

  stage_name = "live"

  rest_api_id = aws_api_gateway_rest_api.pollapp.id

  triggers = {
    redeployment = sha1(join(",",
      [
        jsonencode(aws_api_gateway_rest_api.pollapp.body),
        jsonencode(aws_api_gateway_integration.pollapp),
        jsonencode(aws_api_gateway_method.pollapp)
      ]
    ))
  }

  variables = {
    deployed_at = formatdate("YYYY-MM-DD HH:mm:ss", timestamp())
  }

  lifecycle {
    create_before_destroy = true
  }
}

################################################################################
# Lambda integrations
################################################################################
resource "aws_lambda_permission" "lambdas" {
  function_name = aws_lambda_function.lambda.function_name

  statement_id = "AllowAPIGatewayInvoke"
  action       = "lambda:InvokeFunction"
  principal    = "apigateway.amazonaws.com"
  source_arn   = "${aws_api_gateway_rest_api.pollapp.execution_arn}/*/*"
}

resource "aws_api_gateway_method" "pollapp" {
  http_method = "ANY"
  rest_api_id = aws_api_gateway_rest_api.pollapp.id
  resource_id = aws_api_gateway_rest_api.pollapp.root_resource_id
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "pollapp" {
  uri                     = aws_lambda_function.lambda.invoke_arn
  rest_api_id             = aws_api_gateway_rest_api.pollapp.id
  resource_id             = aws_api_gateway_rest_api.pollapp.root_resource_id
  http_method             = aws_api_gateway_method.pollapp.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
}