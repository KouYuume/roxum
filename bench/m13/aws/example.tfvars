region      = "ap-northeast-1"
aws_profile = "<your AWS CLI profile>"

# Fill these only after account, AZ offerings, and AMI verification.
# expected_account_id = "<verified account ID>"
# availability_zone   = "<verified AZ in ap-northeast-1>"
# ami_id               = "<pinned Amazon Linux 2023 x86_64 AMI>"

server_instance_type = "c7i.2xlarge"
client_instance_type = "c7i.4xlarge"
root_volume_gib      = 40
shutdown_after_hours = 4
