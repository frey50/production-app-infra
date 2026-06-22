output "server_public_ip" {
  description = "The public IP address of our production cloud server"
  value       = aws_instance.app_server.public_ip
}