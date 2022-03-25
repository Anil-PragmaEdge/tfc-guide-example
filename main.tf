provider "aws" {
  region = var.region
}

data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"] # Canonical
}

resource "aws_instance" "ubuntu" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.instance_type
  associate_public_ip_address = var.associate_public_ipaddress_for_instance
  tenancy                     = var.tenancy
  availability_zone           = var.availability_zone_instance
  subnet_id                   = aws_subnet.pubsub.id
  key_name                    = aws_key_pair.key_pair.key_name
  vpc_security_group_ids      = [aws_security_group.sg1.id]
  monitoring                  = var.monitoring
  root_block_device {
    delete_on_termination = var.delete_rbs_on_termination
    volume_size           = var.root_volume_size
    volume_type           = var.root_volume_type
  }

  tags = {
    Name = var.instance_name
  }
}
resource "tls_private_key" "key_pair" {
  algorithm = "RSA"
  rsa_bits  = 4096
}
# Create the Key Pair
resource "aws_key_pair" "key_pair" {
  key_name   = "test-key-pair"
  public_key = tls_private_key.key_pair.public_key_openssh
}
# Save file
resource "local_file" "ssh_key" {
  filename = "${aws_key_pair.key_pair.key_name}.pem"
  content  = tls_private_key.key_pair.private_key_pem
}

resource "aws_vpc" "automation_vpc" {
  cidr_block = var.vpc_cidr_block
  tags = {
    Name = var.vpc_name
  }
}

resource "aws_subnet" "pubsub" {
  cidr_block                      = var.public_cidr_block
  vpc_id                          = aws_vpc.automation_vpc.id
  assign_ipv6_address_on_creation = var.assign_ipv6_address_on_creation_pubsub
  availability_zone               = var.availability_zone_pubsub
  depends_on                      = [aws_vpc.automation_vpc]
  tags = {
    Name = var.public_subnet_name
  }
}

resource "aws_subnet" "privsub" {
  cidr_block                      = var.private_cidr_block
  vpc_id                          = aws_vpc.automation_vpc.id
  assign_ipv6_address_on_creation = var.assign_ipv6_address_on_creation_prvsub
  availability_zone               = var.availability_zone_prvsub
  depends_on                      = [aws_subnet.pubsub]
  tags = {
    Name = var.private_subnet_name
  }
}


resource "aws_internet_gateway" "myigw" {
  depends_on = [aws_subnet.privsub]
  vpc_id     = aws_vpc.automation_vpc.id
  tags = {
    Name = "my-internet-gateway"
  }
}

resource "aws_route_table" "mypubroute" {
  vpc_id     = aws_vpc.automation_vpc.id
  depends_on = [aws_internet_gateway.myigw]
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.myigw.id
  }
}

resource "aws_route_table_association" "mypubrouteassociation" {
  depends_on     = [aws_route_table.mypubroute]
  subnet_id      = aws_subnet.pubsub.id
  route_table_id = aws_route_table.mypubroute.id
}

resource "aws_eip" "nateip" {
  vpc        = true
  depends_on = [aws_route_table_association.mypubrouteassociation]
  instance   = aws_instance.automation_server.id
  tags = {
    Name = var.elastic_ip_name
  }
}

resource "aws_eip_association" "vm-eip-association" {
  instance_id   = aws_instance.automation_server.id
  allocation_id = aws_eip.nateip.id
}

resource "aws_nat_gateway" "mynatgw" {
  allocation_id = aws_eip.nateip.id
  subnet_id     = aws_subnet.pubsub.id
  depends_on    = [aws_eip.nateip]
}

resource "aws_route_table" "myprivroute" {
  vpc_id     = aws_vpc.automation_vpc.id
  depends_on = [aws_nat_gateway.mynatgw]
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_nat_gateway.mynatgw.id
  }
}

resource "aws_route_table_association" "myprivrouteassociation" {
  route_table_id = aws_route_table.myprivroute.id
  depends_on     = [aws_route_table.myprivroute]
  subnet_id      = aws_subnet.privsub.id
}

resource "aws_route_table_association" "myprivrtassociation" {
  route_table_id = aws_route_table.myprivroute.id
  depends_on     = [aws_route_table_association.myprivrouteassociation]
  subnet_id      = aws_subnet.privsub.id
}

resource "aws_security_group" "sg1" {
  name        = var.security_group_name
  description = "Allow TLS inbound traffic"
  vpc_id      = aws_vpc.automation_vpc.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 3389
    to_port     = 3389
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow incoming RDP connections (Windows)"
  }
  ingress {
    description = "HTTP"
    from_port   = 80
    protocol    = "tcp"
    to_port     = 80
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "HTTP"
    from_port   = 1521
    protocol    = "tcp"
    to_port     = 1521
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "ICMP"
    from_port   = -1
    protocol    = "ICMP"
    to_port     = -1
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 10000
    protocol    = "tcp"
    to_port     = 20000
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "automation-sg"
  }
}

resource "aws_default_security_group" "default" {
  vpc_id     = aws_vpc.automation_vpc.id
  depends_on = [aws_security_group.sg1]
  ingress {
    protocol    = "tcp"
    self        = true
    from_port   = 3306
    to_port     = 3306
    cidr_blocks = ["10.0.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_db_subnet_group" "database-subnet-group" {
  name        = "database subnets"
  subnet_ids  = [aws_subnet.pubsub.id, aws_subnet.privsub.id]
  description = "Subnets for Database Instance"

  tags = {
    Name = "Database Subnets"
  }
}
resource "aws_db_instance" "automation_db" {
  depends_on                            = [aws_instance.automation_server]
  instance_class                        = var.db_instance_class
  allocated_storage                     = var.allocated_storage
  auto_minor_version_upgrade            = var.auto_minor_version_upgrade
  backup_retention_period               = var.backup_retention_period
  publicly_accessible                   = var.publicly_accessible
  performance_insights_enabled          = var.performance_insights_enabled
  performance_insights_retention_period = var.performance_insights_retention_period
  engine                                = var.engine
  engine_version                        = var.engine_version
  name                                  = var.database_name
  username                              = var.database_username
  password                              = var.database_password
  identifier                            = var.database-instance-identifier
  storage_encrypted                     = var.storage_encrypted
  storage_type                          = var.storage_type
  skip_final_snapshot                   = var.skip_final_snapshot
  port                                  = var.database_port
  iops                                  = var.iops
  maintenance_window                    = var.maintenance_window
  db_subnet_group_name                  = aws_db_subnet_group.database-subnet-group.name
  vpc_security_group_ids                = [aws_security_group.sg1.id]
  multi_az                              = true
  tags = {
    Name = "automation_db"
  }
}
