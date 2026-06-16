output "karpenter_controller_role_arn" {
  description = "ARN of the Karpenter controller IAM role — put this in environments/<cluster>.yaml"
  value       = aws_iam_role.karpenter_controller.arn
}

output "karpenter_node_role_name" {
  description = "Name of the Karpenter node IAM role — put this in ec2nodeclass.yaml spec.role"
  value       = aws_iam_role.karpenter_node.name
}

output "karpenter_node_role_arn" {
  description = "ARN of the Karpenter node IAM role"
  value       = aws_iam_role.karpenter_node.arn
}

output "karpenter_interruption_queue_name" {
  description = "SQS queue name for Karpenter interruption handling — put this in environments/<cluster>.yaml"
  value       = aws_sqs_queue.karpenter.name
}

output "karpenter_interruption_queue_url" {
  description = "SQS queue URL"
  value       = aws_sqs_queue.karpenter.url
}
