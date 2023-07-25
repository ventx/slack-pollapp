resource "aws_acm_certificate" "pollapp_api" {
  provider          = aws.us-east-1
  domain_name       = local.api_url
  validation_method = "DNS"
}

resource "aws_route53_record" "pollapp_api_domain_validation" {
  provider = aws.us-east-1
  for_each = { for dvo in aws_acm_certificate.pollapp_api.domain_validation_options : dvo.domain_name => {
    name    = dvo.resource_record_name
    record  = dvo.resource_record_value
    type    = dvo.resource_record_type
    zone_id = data.aws_route53_zone.pollapp.zone_id
    }
  }
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  zone_id = data.aws_route53_zone.pollapp.zone_id
  ttl     = 60
}

resource "aws_acm_certificate_validation" "pollapp_api" {
  provider        = aws.us-east-1
  certificate_arn = aws_acm_certificate.pollapp_api.arn
  validation_record_fqdns = [
    for record in aws_route53_record.pollapp_api_domain_validation : record.fqdn
  ]
}
