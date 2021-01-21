terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.0"
    }
    checkly = {
      source  = "checkly/checkly"
      version = "0.8.0"
    }
  }
}


variable "checkly_api_key" {
  type = string
}

variable "checkly_alert_email" {
  type = string
}

locals {
  website_domain = "vassbence.com"
  src            = "${abspath("../src")}/"
  # only requests with this User-Agent can access the S3 bucket (so search engines can't index it)
  # https://developers.google.com/search/docs/advanced/guidelines/duplicate-content
  required_user_agent         = "go_away_google"
  static_folder_cache_control = "public, immutable, max-age=31536000, must-revalidate"
  mime_types = {
    html  = "text/html"
    css   = "text/css"
    woff2 = "font/woff2"
    jpg   = "image/jpg"
    webp  = "image/webp"
  }
}

provider "aws" {
  region                  = "eu-central-1"
  shared_credentials_file = "~/.aws/credentials"
}

provider "aws" {
  alias  = "us-east-1"
  region = "us-east-1"
}

provider "checkly" {
  api_key = var.checkly_api_key
}

data "aws_route53_zone" "main" {
  name         = local.website_domain
  private_zone = false
}

resource "aws_acm_certificate" "wildcard_website" {
  provider = aws.us-east-1

  domain_name               = local.website_domain
  subject_alternative_names = ["*.${local.website_domain}"]
  validation_method         = "DNS"
}

resource "aws_route53_record" "wildcard_validation" {
  for_each = {
    for dvo in aws_acm_certificate.wildcard_website.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  zone_id         = data.aws_route53_zone.main.zone_id
  ttl             = "60"
}

resource "aws_acm_certificate_validation" "wildcard_cert" {
  provider = aws.us-east-1

  certificate_arn         = aws_acm_certificate.wildcard_website.arn
  validation_record_fqdns = [for record in aws_route53_record.wildcard_validation : record.fqdn]
}

data "aws_acm_certificate" "wildcard_website" {
  provider = aws.us-east-1

  depends_on = [
    aws_acm_certificate.wildcard_website,
    aws_route53_record.wildcard_validation,
    aws_acm_certificate_validation.wildcard_cert,
  ]

  domain      = local.website_domain
  statuses    = ["ISSUED"]
  most_recent = true
}

resource "aws_s3_bucket" "website_root" {
  bucket        = "${local.website_domain}-root"
  force_destroy = true

  website {
    index_document = "index.html"
  }
}

resource "aws_s3_bucket_policy" "update_website_root_bucket_policy" {
  bucket = aws_s3_bucket.website_root.id

  policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PublicRead",
      "Principal": {
        "AWS": "*"
      },
      "Effect": "Allow",
      "Action": [
        "s3:GetObject"
      ],
      "Resource": ["${aws_s3_bucket.website_root.arn}/*"],
      "Condition": {
        "StringEquals": {
          "aws:UserAgent": "${local.required_user_agent}"
        }
      }
    }
  ]
}
POLICY
}

resource "aws_s3_bucket" "website_redirect" {
  bucket        = "${local.website_domain}-redirect"
  force_destroy = true

  website {
    redirect_all_requests_to = "https://${local.website_domain}"
  }
}

resource "aws_cloudfront_distribution" "website_cdn_root" {
  enabled     = true
  price_class = "PriceClass_All"
  aliases     = [local.website_domain]

  origin {
    origin_id   = "origin-bucket-${aws_s3_bucket.website_root.id}"
    domain_name = aws_s3_bucket.website_root.website_endpoint

    custom_origin_config {
      origin_protocol_policy = "http-only"
      http_port              = 80
      https_port             = 443
      origin_ssl_protocols   = ["TLSv1.2", "TLSv1.1", "TLSv1"]
    }

    custom_header {
      name  = "User-Agent"
      value = local.required_user_agent
    }
  }

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD", "OPTIONS"]
    target_origin_id = "origin-bucket-${aws_s3_bucket.website_root.id}"
    min_ttl          = "0"
    default_ttl      = "300"
    max_ttl          = "1200"

    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn = data.aws_acm_certificate.wildcard_website.arn
    ssl_support_method  = "sni-only"
  }

  lifecycle {
    ignore_changes = [viewer_certificate]
  }
}

resource "aws_route53_record" "website_cdn_root_record" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = local.website_domain
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.website_cdn_root.domain_name
    zone_id                = aws_cloudfront_distribution.website_cdn_root.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_cloudfront_distribution" "website_cdn_redirect" {
  enabled     = true
  price_class = "PriceClass_All"
  aliases     = ["www.${local.website_domain}"]

  origin {
    origin_id   = "origin-bucket-${aws_s3_bucket.website_redirect.id}"
    domain_name = aws_s3_bucket.website_redirect.website_endpoint

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1", "TLSv1.1", "TLSv1.2"]
    }

    custom_header {
      name  = "User-Agent"
      value = local.required_user_agent
    }
  }

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT", "DELETE"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "origin-bucket-${aws_s3_bucket.website_redirect.id}"
    min_ttl          = "0"
    default_ttl      = "300"
    max_ttl          = "1200"

    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn = data.aws_acm_certificate.wildcard_website.arn
    ssl_support_method  = "sni-only"
  }

  lifecycle {
    ignore_changes = [viewer_certificate]
  }
}

resource "aws_route53_record" "website_cdn_redirect_record" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "www.${local.website_domain}"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.website_cdn_redirect.domain_name
    zone_id                = aws_cloudfront_distribution.website_cdn_redirect.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_s3_bucket_object" "website_files" {
  for_each      = fileset(local.src, "**/*.*")
  bucket        = aws_s3_bucket.website_root.bucket
  key           = replace(each.value, local.src, "")
  source        = "${local.src}${each.value}"
  etag          = filemd5("${local.src}${each.value}")
  content_type  = lookup(local.mime_types, split(".", each.value)[length(split(".", each.value)) - 1])
  cache_control = split("/", each.value)[0] == "static" ? local.static_folder_cache_control : null
}

resource "checkly_alert_channel" "email" {
  email {
    address = var.checkly_alert_email
  }
}

resource "checkly_check" "root_domain_check" {
  name                   = "root_domain_check"
  type                   = "API"
  activated              = true
  should_fail            = false
  frequency              = 15
  double_check           = true
  ssl_check              = true
  degraded_response_time = 300
  max_response_time      = 500

  locations = [
    "eu-central-1",
    "eu-west-2",
    "eu-south-1",
    "us-east-1",
  ]

  alert_settings {
    escalation_type = "RUN_BASED"

    run_based_escalation {
      failed_run_threshold = 2
    }

    ssl_certificates {
      enabled         = true
      alert_threshold = 30
    }

    reminders {
      amount   = 5
      interval = 30
    }
  }

  alert_channel_subscription {
    channel_id = checkly_alert_channel.email.id
    activated  = true
  }

  request {
    url              = "https://${local.website_domain}/"
    follow_redirects = false
    assertion {
      source     = "STATUS_CODE"
      comparison = "EQUALS"
      target     = "200"
    }
  }
}

resource "checkly_check" "www_domain_check" {
  name                   = "www_domain_check"
  type                   = "API"
  activated              = true
  should_fail            = false
  frequency              = 15
  double_check           = true
  ssl_check              = true
  degraded_response_time = 300
  max_response_time      = 500

  locations = [
    "eu-central-1",
    "eu-west-2",
    "eu-south-1",
    "us-east-1",
  ]

  alert_settings {
    escalation_type = "RUN_BASED"

    run_based_escalation {
      failed_run_threshold = 2
    }

    ssl_certificates {
      enabled         = true
      alert_threshold = 30
    }

    reminders {
      amount   = 5
      interval = 30
    }
  }

  alert_channel_subscription {
    channel_id = checkly_alert_channel.email.id
    activated  = true
  }

  request {
    url              = "https://www.${local.website_domain}/"
    follow_redirects = true
    assertion {
      source     = "STATUS_CODE"
      comparison = "EQUALS"
      target     = "200"
    }
  }
}

