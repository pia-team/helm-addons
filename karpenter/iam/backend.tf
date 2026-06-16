# Using local state for now.
# Uncomment and configure when an S3 bucket and DynamoDB table are available:
# terraform {
#   backend "s3" {
#     bucket         = "terraform-state-bucket-name-here"
#     key            = "helm-addons/karpenter/iam/terraform.tfstate"
#     region         = "eu-west-1"
#     encrypt        = true
#     dynamodb_table = "terraform-state-lock-table-name-here"
#   }
# }
