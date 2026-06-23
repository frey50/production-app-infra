terraform {
  required_version = ">= 1.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "eu-central-1" # Frankfurt datacenter building
}

# 🔑 1. The Modern Cryptographic Public Key Lock Resource
resource "aws_key_pair" "deployer" {
  key_name   = "production-deployer-key-v2"
  public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILR6dKotaAhb9vJCFbxSI7qAAJtbgA3OoEGIkrAwJ/If freysair@Freys-MacBook-Air.local"
}

# 💻 2. The Compute Server Instance Resource
resource "aws_instance" "web" {
  ami                     = "ami-01e444924a2233b07"
  instance_type           = "t3.micro"
  subnet_id               = aws_subnet.public_subnet.id
  vpc_security_group_ids  = [aws_security_group.app_sg.id]
  key_name                = aws_key_pair.deployer.key_name
  iam_instance_profile    = aws_iam_instance_profile.ssm_profile.name
}

# 🌐 1. The Main VPC (Our isolated cloud data center)
resource "aws_vpc" "production_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "production-vpc"
  }
}

# 🔓 2. Public Subnet (Where your Go API and Nginx Proxy will live)
resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.production_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "eu-central-1a" 
  map_public_ip_on_launch = true            # Automatically gives servers a public internet IP

  tags = {
    Name = "production-public-subnet"
  }
}

# 🔒 3. Private Subnet (Where your PostgreSQL Database will hide)
resource "aws_subnet" "private_subnet" {
  vpc_id            = aws_vpc.production_vpc.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "eu-central-1a"
  
  # map_public_ip_on_launch is false by default -> No direct public access allowed!

  tags = {
    Name = "production-private-subnet"
  }
}

# 🚪 4. Internet Gateway (The Front Door to the Public Internet)
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.production_vpc.id

  tags = {
    Name = "production-igw"
  }
}

# 🗺️ 5. Public Route Table (The Custom Road Map)
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.production_vpc.id

  # This route says: Any traffic destined for anywhere on the internet (0.0.0.0/0), send it out the Front Door (IGW)
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "production-public-rt"
  }
}

# 🔗 6. Connect the Road Map to our Public Subnet Room
resource "aws_route_table_association" "public_association" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
} 

# 🛡️ 7. Security Group (The Server's Firewall Bouncer)
resource "aws_security_group" "app_sg" {
  name        = "production-app-sg"
  description = "Allow inbound HTTP and SSH traffic"
  vpc_id      = aws_vpc.production_vpc.id

  # Inbound Rule: Allow Web Traffic (Nginx) from anywhere in the world
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Inbound Rule: Allow Secure Shell (SSH) management traffic
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # In real production, you'd restrict this to your exact home IP!
  }

  # Outbound Rule: Allow the server to talk to the outside world freely (to download updates/Docker images)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1" # Means ALL protocols
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "production-app-sg"
  }
}

# 🖥️ 8. EC2 Compute Layer (Our Virtual Linux Machine)
resource "aws_instance" "app_server" {
  # Ubuntu 24.04 LTS AMI ID for eu-central-1 (Frankfurt)
  ami           = "ami-0084a47cc718c111a" 
  instance_type = "t3.micro" # Strictly 100% AWS Free Tier eligible!

  subnet_id              = aws_subnet.public_subnet.id
  vpc_security_group_ids = [aws_security_group.app_sg.id]

  # Root storage volume configuration
  root_block_device {
    volume_size = 8 # 8 GB of SSD storage, standard and free
    volume_type = "gp3"
  }

  tags = {
    Name = "production-app-server"
  }
}

# 🪣 9. Amazon S3 Bucket (Object Storage for Files/Backups)
resource "aws_s3_bucket" "app_storage" {
  # CRITICAL: AWS bucket names must be globally unique across the ENTIRE world!
  # Change "yourname" to your actual name or initials so it doesn't conflict.
  bucket        = "production-app-storage-yourname-2026" 
  force_destroy = true # Allows terraform to easily delete it later if we clean up

  tags = {
    Name        = "production-app-storage"
    Environment = "Production"
  }
}

# ---------------------------------------------------------------------------
# SSM access for EC2 (lets AWS manage the instance without inbound SSH)
# ---------------------------------------------------------------------------

resource "aws_iam_role" "ssm_role" {
  name = "production-ec2-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm_profile" {
  name = "production-ec2-ssm-profile"
  role = aws_iam_role.ssm_role.name
}

# ---------------------------------------------------------------------------
# GitHub Actions OIDC -> AWS (no stored AWS keys needed)
# ---------------------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

resource "aws_iam_role" "github_actions_deploy" {
  name = "github-actions-deploy-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:frey50/production-app-infra:ref:refs/heads/main"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_ssm_deploy" {
  name = "github-ssm-send-command"
  role = aws_iam_role.github_actions_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssm:SendCommand",
        "ssm:GetCommandInvocation",
        "ssm:ListCommandInvocations"
      ]
      Resource = "*"
    }]
  })
}


