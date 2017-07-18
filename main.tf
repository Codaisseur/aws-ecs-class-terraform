provider "aws" {
  region     = "eu-west-1"
  profile 	 = "codaisseur"
}

variable "name" {
	default = "brams_awesome_cluster"
}

# VPC

module "vpc" {
  source = "github.com/terraform-community-modules/tf_aws_vpc"
  name = "${var.name}"

  # recommended IP-block that's not publicly routed
  cidr = "10.0.0.0/16"

  # we define 3 private and 3 public subnets, for 3 AZs
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  # we span all AZs for future-proofing
  azs = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]

  # enabling this makes use over in-VPC Route53 usage possible
  enable_dns_hostnames = true
  enable_dns_support = true
}

# EC2 instance

resource "aws_security_group" "allow_3001_inbound" {
  name = "${module.vpc.vpc_id}-allow_3001_inbound"
  description = "Allow all inbound traffic from 3001"
  vpc_id = "${module.vpc.vpc_id}"

  ingress = {
    from_port = 3001
    to_port = 3001
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }  
}

data "template_file" "user_data" {
  template = "${file("${path.module}/templates/user_data_ec2")}"

  vars {
    cluster_name = "${var.name}"
  }
}

resource "aws_instance" "ecs_runner" {
  ami           = "ami-809f84e6"
  instance_type = "t2.micro"
	user_data     = "${data.template_file.user_data.rendered}"
  iam_instance_profile = "${aws_iam_instance_profile.ec2_ecs.name}"
  subnet_id = "${module.vpc.public_subnets[1]}"
  vpc_security_group_ids = [
    "${aws_security_group.allow_3001_inbound.id}",
    "${module.vpc.default_security_group_id}",
  ]
  
  tags = {
    MyName = "${var.name}"
  }
}

# ECS cluster

resource "aws_ecs_cluster" "primary" {
  name = "${var.name}"
}

# ECS task definition

data "template_file" "awesome_container_definition" {    
  template = "${file("${path.module}/templates/awesome-container-def.json")}"
}

resource "aws_ecs_task_definition" "awesome_service" {    
  family = "awesome"
  container_definitions = "${data.template_file.awesome_container_definition.rendered}"
}

# ECS service

resource "aws_ecs_service" "main" {
  name = "awesome-service"
  cluster = "${aws_ecs_cluster.primary.id}"
  task_definition = "${aws_ecs_task_definition.awesome_service.arn}"
  desired_count = 1
}

# IAM role we need for EC2 running ECS

data "template_file" "ec2_assume_role" {
  template = "${file("${path.module}/templates/ec2-assume-role.json")}"
}

resource "aws_iam_role" "ec2_ecs" {
  name = "ec2_role_for_ecs_${var.name}"
  assume_role_policy = "${data.template_file.ec2_assume_role.rendered}"
}

resource "aws_iam_instance_profile" "ec2_ecs" {
  name = "ec2_role_for_ecs_${var.name}"
  role = "${aws_iam_role.ec2_ecs.name}"
}

resource "aws_iam_role_policy_attachment" "attach_ecs_for_ec2" {
  role       = "${aws_iam_role.ec2_ecs.name}"
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}