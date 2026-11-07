output "hosts" {
  description = "Connect through SSM; HTTP benchmarks must use the server's private IP."
  value = {
    for role, instance in aws_instance.host : role => {
      instance_id = instance.id
      private_ip  = instance.private_ip
      type        = instance.instance_type
      session     = "aws --profile ${var.aws_profile} --region ${var.region} ssm start-session --target ${instance.id}"
    }
  }
}

output "server_url" {
  value = "http://${aws_instance.host["server"].private_ip}:8080"
}

output "experiment" {
  value = {
    region               = var.region
    availability_zone    = var.availability_zone
    ami_id               = data.aws_ami.pinned.id
    shutdown_after_hours = var.shutdown_after_hours
    root_volume_gib_each = var.root_volume_gib
  }
}
