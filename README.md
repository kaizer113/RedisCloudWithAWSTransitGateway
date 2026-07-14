# Redis Cloud Pro + AWS Transit Gateway Terraform

This repository contains a single Terraform stack that creates:

1. A small Redis Cloud Pro subscription and 2 GB database.
2. AWS Transit Gateway connectivity between the Redis Cloud subscription and an AWS VPC.

## Authentication

Redis Cloud credentials are read by the Redis Cloud Terraform provider from:

```bash
export REDISCLOUD_ACCESS_KEY="..."
export REDISCLOUD_SECRET_KEY="..."
```

### Configure AWS SSO

Use a dedicated Terraform profile instead of reusing `default`:

```bash
aws configure sso --profile redis-tgw
```

When prompted:

```text
SSO session name (Recommended): redis
SSO start URL: https://d-<your-aws-access-portal>.awsapps.com/start
SSO region: <IAM-Identity-Center-region>
SSO registration scopes [sso:account:access]: sso:account:access
```

Important: the SSO start URL is the AWS IAM Identity Center access portal URL. If Okta is your identity provider, open Okta first, launch the AWS / IAM Identity Center app, then get the AWS access portal URL from the AWS credentials page. It usually looks like `https://d-xxxxxxxxxx.awsapps.com/start` or a custom `https://...awsapps.com/start` URL.

After configuration:

```bash
aws sso login --profile redis-tgw
aws sts get-caller-identity --profile redis-tgw
```

Then set `aws_profile = "redis-tgw"` in `terraform.tfvars`, or run:

```bash
export AWS_PROFILE=redis-tgw
```

## Usage

Copy the example variables:

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with the Redis Cloud names/settings, AWS profile, AWS resource name prefix, and `aws_vpc_id`.

Marketplace billing is the default:

```hcl
payment_method = "marketplace"
```

For credit-card accounts, set `payment_method = "credit-card"` and Terraform will query the configured Redis Cloud payment method. For direct-contract accounts that do not require a payment method, set `payment_method = null`.

Terraform discovers the VPC CIDR, subnets, and route tables from `aws_vpc_id`. Optional override variables are available in `main.tf` for advanced cases.

The Redis Cloud producer CIDR defaults to `192.168.0.0/24`; make sure it does not overlap the AWS VPC CIDR.

Apply:

```bash
make apply
```

## Confirmation Prompts

Make-based apply and destroy commands pass Terraform's `-auto-approve` flag.
To keep Terraform's confirmation prompt, run:

```bash
make apply TF_AUTO_APPROVE=
make destroy TF_AUTO_APPROVE=
```

## Destroy

Use the same Redis Cloud and AWS credentials/profile that were used for apply:

```bash
make destroy
```
