data "aws_ami" "pinned" {
  owners = ["amazon"]
  filter {
    name   = "image-id"
    values = [var.ami_id]
  }
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-6.1-x86_64"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

resource "aws_vpc" "bench" {
  cidr_block           = "10.77.0.0/24"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = var.name }
}

resource "aws_subnet" "bench" {
  vpc_id            = aws_vpc.bench.id
  cidr_block        = "10.77.0.0/24"
  availability_zone = var.availability_zone
  tags              = { Name = var.name }
}

resource "aws_internet_gateway" "bench" {
  vpc_id = aws_vpc.bench.id
  tags   = { Name = var.name }
}

resource "aws_route_table" "bench" {
  vpc_id = aws_vpc.bench.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.bench.id
  }
  tags = { Name = var.name }
}

resource "aws_route_table_association" "bench" {
  subnet_id      = aws_subnet.bench.id
  route_table_id = aws_route_table.bench.id
}

resource "aws_placement_group" "bench" {
  name     = var.name
  strategy = "cluster"
}

resource "aws_security_group" "server" {
  name_prefix = "${var.name}-server-"
  description = "Benchmark HTTP from the load generator only; administration via SSM"
  vpc_id      = aws_vpc.bench.id
}

resource "aws_security_group" "client" {
  name_prefix = "${var.name}-client-"
  description = "No inbound connections; administration via SSM"
  vpc_id      = aws_vpc.bench.id
}

resource "aws_vpc_security_group_ingress_rule" "benchmark" {
  security_group_id            = aws_security_group.server.id
  referenced_security_group_id = aws_security_group.client.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}

resource "aws_vpc_security_group_egress_rule" "outbound" {
  for_each          = { server = aws_security_group.server.id, client = aws_security_group.client.id }
  security_group_id = each.value
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_iam_role" "ssm" {
  name_prefix = "${var.name}-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm" {
  name_prefix = "${var.name}-"
  role        = aws_iam_role.ssm.name
}

resource "aws_iam_role" "client" {
  name_prefix        = "${var.name}-client-"
  assume_role_policy = aws_iam_role.ssm.assume_role_policy
}

resource "aws_iam_role_policy_attachment" "client_ssm" {
  role       = aws_iam_role.client.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "client" {
  name_prefix = "${var.name}-client-"
  role        = aws_iam_role.client.name
}

resource "aws_iam_role_policy" "client_control" {
  role = aws_iam_role.client.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "ssm:SendCommand"
        Resource = [
          "arn:aws:ssm:${var.region}::document/AWS-RunShellScript",
          "arn:aws:ec2:${var.region}:${var.expected_account_id}:instance/${aws_instance.host["server"].id}"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:GetCommandInvocation", "ssm:CancelCommand"]
        Resource = "*"
        Condition = {
          StringEquals = { "aws:RequestedRegion" = var.region }
        }
      }
    ]
  })
}

resource "aws_instance" "host" {
  for_each = {
    server = { instance_type = var.server_instance_type, security_group = aws_security_group.server.id }
    client = { instance_type = var.client_instance_type, security_group = aws_security_group.client.id }
  }
  ami                                  = data.aws_ami.pinned.id
  instance_type                        = each.value.instance_type
  subnet_id                            = aws_subnet.bench.id
  vpc_security_group_ids               = [each.value.security_group]
  placement_group                      = aws_placement_group.bench.id
  associate_public_ip_address          = true
  iam_instance_profile                 = each.key == "client" ? aws_iam_instance_profile.client.name : aws_iam_instance_profile.ssm.name
  instance_initiated_shutdown_behavior = "stop"
  user_data_replace_on_change          = true
  user_data = templatefile("${path.module}/bootstrap.sh.tftpl", {
    shutdown_after_hours = var.shutdown_after_hours
  })

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_gib
    encrypted             = true
    delete_on_termination = true
  }

  tags = { Name = "${var.name}-${each.key}", Role = each.key }
  depends_on = [
    aws_route_table_association.bench,
    aws_iam_role_policy_attachment.ssm,
    aws_iam_role_policy_attachment.client_ssm,
    aws_vpc_security_group_egress_rule.outbound,
  ]
}
