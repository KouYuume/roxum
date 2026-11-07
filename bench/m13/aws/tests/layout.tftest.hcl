mock_provider "aws" {
  mock_data "aws_ami" {
    defaults = {
      id = "ami-0123456789abcdef0"
    }
  }
}

variables {
  aws_profile         = "benchmark"
  expected_account_id = "123456789012"
  availability_zone   = "ap-northeast-1a"
  ami_id              = "ami-0123456789abcdef0"
}

run "isolated_two_host_layout" {
  command = plan

  assert {
    condition     = length(aws_instance.host) == 2
    error_message = "The experiment must contain exactly a client and a server."
  }
  assert {
    condition     = aws_instance.host["server"].instance_type == "c7i.2xlarge" && aws_instance.host["client"].instance_type == "c7i.4xlarge"
    error_message = "The initial client budget must exceed the server budget."
  }
  assert {
    condition     = aws_subnet.bench.availability_zone == "ap-northeast-1a" && aws_placement_group.bench.strategy == "cluster"
    error_message = "Hosts must share one AZ and a cluster placement group."
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.benchmark.from_port == 8080 && aws_vpc_security_group_ingress_rule.benchmark.to_port == 8080 && aws_vpc_security_group_ingress_rule.benchmark.cidr_ipv4 == null
    error_message = "Benchmark ingress must use a source security group, not a public CIDR."
  }
  assert {
    condition     = alltrue([for host in aws_instance.host : host.metadata_options[0].http_tokens == "required" && host.root_block_device[0].encrypted && host.root_block_device[0].delete_on_termination])
    error_message = "Both hosts require IMDSv2 and encrypted disposable root volumes."
  }
  assert {
    condition     = alltrue([for host in aws_instance.host : strcontains(host.user_data, "OnBootSec=4h") && host.instance_initiated_shutdown_behavior == "stop"])
    error_message = "Both hosts must stop after the default four-hour window."
  }
}

# Integer hours 1..24: check both bounds, their nearest valid neighbors, and invalid outsiders.
run "reject_zero_duration" {
  command = plan
  variables { shutdown_after_hours = 0 }
  expect_failures = [var.shutdown_after_hours]
}

run "minimum_duration" {
  command = plan
  variables { shutdown_after_hours = 1 }
  assert {
    condition     = strcontains(aws_instance.host["server"].user_data, "OnBootSec=1h")
    error_message = "The minimum timer must render as one hour."
  }
}

run "above_minimum_duration" {
  command = plan
  variables { shutdown_after_hours = 2 }
}

run "below_maximum_duration" {
  command = plan
  variables { shutdown_after_hours = 23 }
}

run "maximum_duration" {
  command = plan
  variables { shutdown_after_hours = 24 }
}

run "reject_excess_duration" {
  command = plan
  variables { shutdown_after_hours = 25 }
  expect_failures = [var.shutdown_after_hours]
}

run "reject_other_region_az" {
  command = plan
  variables { availability_zone = "us-east-1a" }
  expect_failures = [var.availability_zone]
}

run "client_control_scope" {
  command = apply
  assert {
    condition = toset(jsondecode(aws_iam_role_policy.client_control.policy).Statement[0].Resource) == toset([
      "arn:aws:ssm:ap-northeast-1::document/AWS-RunShellScript",
      "arn:aws:ec2:ap-northeast-1:123456789012:instance/${aws_instance.host["server"].id}"
    ])
    error_message = "Command execution must target only the benchmark server and approved document."
  }
  assert {
    condition     = aws_instance.host["client"].iam_instance_profile == aws_iam_instance_profile.client.name && aws_instance.host["server"].iam_instance_profile == aws_iam_instance_profile.ssm.name
    error_message = "Client control permissions must not be attached to the server profile."
  }
}
