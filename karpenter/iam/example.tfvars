# Copy to terraform.tfvars and fill in the values.
# Get oidc_provider_arn and oidc_provider_url from:
#   cd ../../terraform/clusters/eks-karpenter-vpa && terraform output

cluster_name      = "eks-karpenter-vpa"
aws_region        = "eu-west-1"
oidc_provider_arn = "arn:aws:iam::<account_id>:oidc-provider/oidc.eks.eu-west-1.amazonaws.com/id/<oidc_id>"
oidc_provider_url = "https://oidc.eks.eu-west-1.amazonaws.com/id/<oidc_id>"
