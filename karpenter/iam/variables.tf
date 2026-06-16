variable "cluster_name" {
  description = "EKS cluster name Karpenter will manage"
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the cluster OIDC provider (from terraform output oidc_provider_arn)"
  type        = string
}

variable "oidc_provider_url" {
  description = "URL of the cluster OIDC provider without https:// prefix (from terraform output oidc_provider_url)"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-1"
}

variable "controller_role_name" {
  description = "Name of the Karpenter controller IAM role"
  type        = string
  default     = ""
}

variable "node_role_name" {
  description = "Name of the IAM role assigned to Karpenter-provisioned nodes"
  type        = string
  default     = ""
}
