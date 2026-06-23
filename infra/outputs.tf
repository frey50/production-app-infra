output "server_public_ip" {
  description = "The public IP address of app_server"
  value       = aws_instance.app_server.public_ip
}

output "web_public_ip" {
  description = "The public IP address of web (used for GitHub Actions EC2_HOST secret if still using SSH)"
  value       = aws_instance.web.public_ip
}

output "web_instance_id" {
  description = "Instance ID of web, needed by GitHub Actions to target it via SSM send-command"
  value       = aws_instance.web.id
}

output "github_actions_role_arn" {
  description = "IAM role ARN GitHub Actions assumes via OIDC to run SSM commands"
  value       = aws_iam_role.github_actions_deploy.arn
}