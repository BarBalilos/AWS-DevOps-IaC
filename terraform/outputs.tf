output "frontend_public_ip" {
  description = "Public IP of the nginx/frontend instance - browse here over HTTP"
  value       = aws_instance.frontend.public_ip
}

output "backend_private_ip" {
  value = aws_instance.backend.private_ip
}

output "worker_private_ip" {
  value = aws_instance.worker.private_ip
}

output "rds_endpoint" {
  description = "RDS connection endpoint"
  value       = aws_db_instance.app.endpoint
}

output "s3_bucket_name" {
  value = aws_s3_bucket.uploads.bucket
}

output "sns_topic_arn" {
  value = aws_sns_topic.app_notifications.arn
}