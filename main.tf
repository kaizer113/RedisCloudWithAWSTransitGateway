terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
    rediscloud = {
      source  = "RedisLabs/rediscloud"
      version = "~> 2.18"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

provider "rediscloud" {}

variable "name_prefix" {
  description = "Prefix used for AWS resource names."
  type        = string
  default     = "redis-tgw"
}

variable "subscription_name" {
  description = "Redis Cloud Pro subscription name."
  type        = string
  default     = "redis-tgw-pro-us-east-1"
}

variable "database_name" {
  description = "Redis Cloud database name."
  type        = string
  default     = "redis-tgw-db"
}

variable "cloud_provider" {
  description = "Cloud provider for the Redis Cloud Pro subscription."
  type        = string
  default     = "AWS"
}

variable "redis_region" {
  description = "Cloud provider region for the Redis Cloud Pro subscription."
  type        = string
  default     = "us-east-1"
}

variable "redis_deployment_cidr" {
  description = "Redis Cloud producer deployment CIDR. Must be a /24 and must not overlap the AWS VPC CIDR."
  type        = string
  default     = "192.168.0.0/24"
}

variable "dataset_size_in_gb" {
  description = "Dataset size for the Redis database."
  type        = number
  default     = 2
}

variable "throughput_measurement_value" {
  description = "Database throughput in operations per second."
  type        = number
  default     = 1000
}

variable "replication" {
  description = "Whether database replication is enabled."
  type        = bool
  default     = false
}

variable "support_oss_cluster_api" {
  description = "Whether the Redis database should support the open-source Redis Cluster API."
  type        = bool
  default     = false
}

variable "enable_public_endpoint" {
  description = "Whether Redis Cloud should expose a public endpoint."
  type        = bool
  default     = true
}

variable "aws_region" {
  description = "AWS region. Must match the Redis Cloud subscription region."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "Optional AWS shared config profile, for example an AWS SSO profile. Leave null to use the normal AWS credential chain."
  type        = string
  default     = null
}

variable "aws_vpc_id" {
  description = "The AWS consumer VPC ID to connect to Redis Cloud. This VPC must be in aws_region."
  type        = string
}

variable "aws_subnet_ids" {
  description = "Optional subnet IDs for the TGW VPC attachment. If empty, Terraform discovers all VPC subnets and selects one per AZ."
  type        = list(string)
  default     = []
}

variable "aws_route_table_ids" {
  description = "Optional route table IDs that should route to Redis Cloud. If empty, Terraform discovers all route tables in the VPC."
  type        = set(string)
  default     = []
}

variable "consumer_vpc_cidrs" {
  description = "Optional CIDR ranges Redis Cloud should route back to through TGW. If empty, Terraform uses the VPC primary CIDR."
  type        = list(string)
  default     = []
}

variable "amazon_side_asn" {
  description = "Private ASN for the AWS side of the Transit Gateway."
  type        = number
  default     = 64512
}

resource "random_password" "database" {
  length  = 32
  special = false
}

data "rediscloud_payment_method" "current" {}

resource "rediscloud_subscription" "pro" {
  name                   = var.subscription_name
  payment_method_id      = data.rediscloud_payment_method.current.id
  memory_storage         = "ram"
  public_endpoint_access = var.enable_public_endpoint

  cloud_provider {
    provider = var.cloud_provider

    region {
      region                       = var.redis_region
      multiple_availability_zones  = false
      networking_deployment_cidr   = var.redis_deployment_cidr
      preferred_availability_zones = []
    }
  }

  creation_plan {
    dataset_size_in_gb           = var.dataset_size_in_gb
    quantity                     = 1
    replication                  = var.replication
    support_oss_cluster_api      = var.support_oss_cluster_api
    throughput_measurement_by    = "operations-per-second"
    throughput_measurement_value = var.throughput_measurement_value
  }

  timeouts {
    create = "60m"
    update = "60m"
    delete = "30m"
  }
}

resource "rediscloud_subscription_database" "database" {
  subscription_id              = rediscloud_subscription.pro.id
  name                         = var.database_name
  dataset_size_in_gb           = var.dataset_size_in_gb
  protocol                     = "redis"
  replication                  = var.replication
  support_oss_cluster_api      = var.support_oss_cluster_api
  data_persistence             = "none"
  throughput_measurement_by    = "operations-per-second"
  throughput_measurement_value = var.throughput_measurement_value
  password                     = random_password.database.result
  enable_default_user          = true

  timeouts {
    create = "60m"
    update = "60m"
    delete = "30m"
  }
}

data "aws_vpc" "consumer" {
  id = var.aws_vpc_id
}

data "aws_subnets" "consumer" {
  filter {
    name   = "vpc-id"
    values = [var.aws_vpc_id]
  }
}

data "aws_subnet" "consumer" {
  for_each = toset(data.aws_subnets.consumer.ids)

  id = each.value
}

data "aws_route_tables" "consumer" {
  vpc_id = var.aws_vpc_id
}

locals {
  discovered_subnet_ids_by_az = {
    for subnet in values(data.aws_subnet.consumer) : subnet.availability_zone => subnet.id...
  }

  discovered_tgw_subnet_ids = [
    for availability_zone, subnet_ids in local.discovered_subnet_ids_by_az : sort(subnet_ids)[0]
  ]

  tgw_subnet_ids     = length(var.aws_subnet_ids) > 0 ? var.aws_subnet_ids : local.discovered_tgw_subnet_ids
  route_table_ids    = length(var.aws_route_table_ids) > 0 ? var.aws_route_table_ids : toset(data.aws_route_tables.consumer.ids)
  consumer_vpc_cidrs = length(var.consumer_vpc_cidrs) > 0 ? var.consumer_vpc_cidrs : [data.aws_vpc.consumer.cidr_block]
}

resource "aws_ec2_transit_gateway" "redis" {
  description                     = "TGW for Redis Cloud connectivity"
  amazon_side_asn                 = var.amazon_side_asn
  auto_accept_shared_attachments  = "enable"
  default_route_table_association = "enable"
  default_route_table_propagation = "enable"
  dns_support                     = "enable"
  vpn_ecmp_support                = "enable"

  tags = {
    Name = var.name_prefix
  }
}

resource "aws_ram_resource_share" "redis_tgw" {
  name                      = "${var.name_prefix}-ram-share"
  allow_external_principals = true

  tags = {
    Name = "${var.name_prefix}-ram-share"
  }
}

resource "aws_ram_resource_association" "redis_tgw" {
  resource_arn       = aws_ec2_transit_gateway.redis.arn
  resource_share_arn = aws_ram_resource_share.redis_tgw.arn
}

resource "aws_ram_principal_association" "redis_account" {
  principal          = rediscloud_subscription.pro.cloud_provider[0].aws_account_id
  resource_share_arn = aws_ram_resource_share.redis_tgw.arn
}

data "rediscloud_transit_gateway_invitations" "redis_tgw" {
  subscription_id              = rediscloud_subscription.pro.id
  wait_for_invitations_timeout = 900

  depends_on = [
    aws_ram_resource_association.redis_tgw,
    aws_ram_principal_association.redis_account
  ]
}

resource "rediscloud_transit_gateway_invitation_acceptor" "redis_tgw" {
  subscription_id   = rediscloud_subscription.pro.id
  tgw_invitation_id = data.rediscloud_transit_gateway_invitations.redis_tgw.invitations[0].id
  action            = "accept"
}

data "rediscloud_transit_gateway" "redis_tgw" {
  subscription_id      = rediscloud_subscription.pro.id
  aws_tgw_uid          = aws_ec2_transit_gateway.redis.id
  wait_for_tgw_timeout = 900

  depends_on = [rediscloud_transit_gateway_invitation_acceptor.redis_tgw]
}

resource "aws_ec2_transit_gateway_vpc_attachment" "consumer_vpc" {
  transit_gateway_id = aws_ec2_transit_gateway.redis.id
  vpc_id             = var.aws_vpc_id
  subnet_ids         = local.tgw_subnet_ids
  dns_support        = "enable"

  tags = {
    Name = "${var.name_prefix}-consumer-vpc"
  }
}

resource "rediscloud_transit_gateway_attachment" "redis" {
  subscription_id = rediscloud_subscription.pro.id
  tgw_id          = data.rediscloud_transit_gateway.redis_tgw.tgw_id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.consumer_vpc]
}

resource "terraform_data" "wait_for_redis_attachment" {
  triggers_replace = [
    rediscloud_transit_gateway_attachment.redis.attachment_uid
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -eu

      if [ -n "$AWS_PROFILE_VALUE" ]; then
        export AWS_PROFILE="$AWS_PROFILE_VALUE"
      fi

      attachment_id="$TGW_ATTACHMENT_ID"

      for attempt in $(seq 1 60); do
        state="$(aws ec2 describe-transit-gateway-attachments \
          --region "$AWS_REGION_VALUE" \
          --transit-gateway-attachment-ids "$attachment_id" \
          --query 'TransitGatewayAttachments[0].State' \
          --output text)"

        echo "Redis Cloud TGW attachment $attachment_id state: $state"

        if [ "$state" = "available" ]; then
          exit 0
        fi

        case "$state" in
          failed|deleted|deleting|rejected|rejecting)
            echo "Redis Cloud TGW attachment $attachment_id reached terminal state: $state" >&2
            exit 1
            ;;
        esac

        sleep 10
      done

      echo "Timed out waiting for Redis Cloud TGW attachment $attachment_id to become available" >&2
      exit 1
    EOT

    environment = {
      AWS_PROFILE_VALUE = coalesce(var.aws_profile, "")
      AWS_REGION_VALUE  = var.aws_region
      TGW_ATTACHMENT_ID = rediscloud_transit_gateway_attachment.redis.attachment_uid
    }
  }
}

resource "rediscloud_transit_gateway_route" "consumer_cidrs" {
  subscription_id = rediscloud_subscription.pro.id
  tgw_id          = data.rediscloud_transit_gateway.redis_tgw.tgw_id
  cidrs           = local.consumer_vpc_cidrs

  depends_on = [terraform_data.wait_for_redis_attachment]
}

resource "aws_route" "redis_producer_cidr" {
  for_each = local.route_table_ids

  route_table_id         = each.value
  destination_cidr_block = var.redis_deployment_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.redis.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.consumer_vpc]
}

output "subscription_id" {
  description = "Redis Cloud subscription ID."
  value       = rediscloud_subscription.pro.id
}

output "database_id" {
  description = "Redis Cloud database ID."
  value       = rediscloud_subscription_database.database.db_id
}

output "redis_aws_account_id" {
  description = "AWS account ID where Redis Cloud created the producer VPC."
  value       = rediscloud_subscription.pro.cloud_provider[0].aws_account_id
}

output "redis_deployment_cidr" {
  description = "Redis Cloud producer VPC CIDR to route from the consumer AWS VPC."
  value       = var.redis_deployment_cidr
}

output "private_endpoint" {
  description = "Private Redis endpoint for TGW connectivity."
  value       = rediscloud_subscription_database.database.private_endpoint
}

output "public_endpoint" {
  description = "Public Redis endpoint, if enabled."
  value       = rediscloud_subscription_database.database.public_endpoint
}

output "database_password" {
  description = "Generated Redis database password."
  value       = random_password.database.result
  sensitive   = true
}

output "transit_gateway_id" {
  description = "AWS Transit Gateway ID."
  value       = aws_ec2_transit_gateway.redis.id
}

output "transit_gateway_arn" {
  description = "AWS Transit Gateway ARN."
  value       = aws_ec2_transit_gateway.redis.arn
}

output "consumer_vpc_attachment_id" {
  description = "AWS TGW attachment ID for the consumer VPC."
  value       = aws_ec2_transit_gateway_vpc_attachment.consumer_vpc.id
}

output "redis_attachment_id" {
  description = "AWS TGW attachment ID for the Redis Cloud producer VPC."
  value       = rediscloud_transit_gateway_attachment.redis.attachment_uid
}

output "selected_tgw_subnet_ids" {
  description = "Subnet IDs used for the AWS TGW VPC attachment."
  value       = local.tgw_subnet_ids
}

output "selected_route_table_ids" {
  description = "Route table IDs updated with the Redis Cloud producer CIDR route."
  value       = local.route_table_ids
}

output "consumer_vpc_cidrs" {
  description = "Consumer CIDRs registered in Redis Cloud."
  value       = local.consumer_vpc_cidrs
}
