data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  ami_id = data.aws_ami.amazon_linux.id
}

resource "aws_instance" "frontend" {
  ami                         = local.ami_id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.frontend.id]
  key_name                    = var.key_pair_name
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.app_profile.name
  source_dest_check           = false

  tags = {
    Name = "${var.project_name}-frontend"
    Role = "frontend"
  }
}

resource "aws_instance" "backend" {
  ami                     = local.ami_id
  instance_type           = var.instance_type
  subnet_id               = aws_subnet.private[0].id
  vpc_security_group_ids  = [aws_security_group.backend.id]
  key_name                = var.key_pair_name
  iam_instance_profile    = aws_iam_instance_profile.app_profile.name

  tags = {
    Name = "${var.project_name}-backend"
    Role = "backend"
  }
}

resource "aws_instance" "worker" {
  ami                     = local.ami_id
  instance_type           = var.instance_type
  subnet_id               = aws_subnet.private[1].id
  vpc_security_group_ids  = [aws_security_group.worker.id]
  key_name                = var.key_pair_name
  iam_instance_profile    = aws_iam_instance_profile.app_profile.name

  tags = {
    Name = "${var.project_name}-worker"
    Role = "worker"
  }
}
