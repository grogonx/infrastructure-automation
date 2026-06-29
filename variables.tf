# =============================================================================
# variables.tf
# Description: Input variable definitions for the AWS infrastructure module.
#              All defaults are set for a non-production environment.
#              Override via terraform.tfvars or -var flags.
# Author:      Joshua Harvey
# =============================================================================

# --- General ---
variable "project_name" {
  description = "Name used to tag and prefix all resources"
  type        = string
  default     = "my-project"
}

variable "environment" {
  description = "Deployment environment (dev, staging, production)"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "production"], var.environment)
    error_message = "environment must be one of: dev, staging, production"
  }
}

variable "aws_region" {
  description = "AWS region to deploy resources into"
  type        = string
  default     = "ca-central-1"
}

variable "owner" {
  description = "Owner tag applied to all resources (e.g. team name or email)"
  type        = string
  default     = "devops-team"
}

# --- VPC / Networking ---
variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "List of CIDR blocks for public subnets (one per AZ)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "List of CIDR blocks for private subnets (one per AZ)"
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}

variable "availability_zones" {
  description = "Availability zones to deploy subnets into"
  type        = list(string)
  default     = ["ca-central-1a", "ca-central-1b"]
}

variable "enable_nat_gateway" {
  description = "Whether to deploy a NAT Gateway for private subnet outbound traffic"
  type        = bool
  default     = true
}

# --- EC2 ---
variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.medium"
}

variable "ami_id" {
  description = "AMI ID for EC2 instances (RHEL 9 ca-central-1 default)"
  type        = string
  default     = "ami-0c9bfc21ac5bf10eb"
}

variable "instance_count" {
  description = "Number of EC2 instances to launch"
  type        = number
  default     = 1
}

variable "key_name" {
  description = "Name of the EC2 key pair for SSH access"
  type        = string
  default     = ""
}

variable "root_volume_size" {
  description = "Root EBS volume size in GB"
  type        = number
  default     = 30
}

variable "allowed_ssh_cidrs" {
  description = "CIDR blocks allowed to SSH into instances (restrict in production)"
  type        = list(string)
  default     = ["10.0.0.0/8"]
}

# --- S3 ---
variable "create_s3_bucket" {
  description = "Whether to create an S3 bucket for this project"
  type        = bool
  default     = true
}

variable "s3_versioning" {
  description = "Enable versioning on the S3 bucket"
  type        = bool
  default     = true
}

variable "s3_lifecycle_days" {
  description = "Days after which objects transition to STANDARD_IA storage"
  type        = number
  default     = 90
}
