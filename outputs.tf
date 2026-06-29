# =============================================================================
# outputs.tf
# Description: Output values exposed after a successful Terraform apply.
#              Reference these in other modules or CI/CD pipelines.
# Author:      Joshua Harvey
# =============================================================================

output "vpc_id" {
  description = "ID of the provisioned VPC"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC"
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "IDs of the public subnets"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs of the private subnets"
  value       = aws_subnet.private[*].id
}

output "nat_gateway_ip" {
  description = "Elastic IP of the NAT Gateway (if enabled)"
  value       = var.enable_nat_gateway ? aws_eip.nat[0].public_ip : null
}

output "ec2_instance_ids" {
  description = "IDs of the provisioned EC2 instances"
  value       = aws_instance.main[*].id
}

output "ec2_private_ips" {
  description = "Private IP addresses of EC2 instances"
  value       = aws_instance.main[*].private_ip
}

output "ec2_security_group_id" {
  description = "ID of the EC2 security group"
  value       = aws_security_group.ec2.id
}

output "s3_bucket_name" {
  description = "Name of the S3 bucket (if created)"
  value       = var.create_s3_bucket ? aws_s3_bucket.main[0].bucket : null
}

output "s3_bucket_arn" {
  description = "ARN of the S3 bucket (if created)"
  value       = var.create_s3_bucket ? aws_s3_bucket.main[0].arn : null
}

output "aws_account_id" {
  description = "AWS account ID resources were deployed into"
  value       = data.aws_caller_identity.current.account_id
}
