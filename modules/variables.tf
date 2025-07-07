variable "instance_type" {
  description = "EC2 Instance Type"
  default = "t2.micro"
}

variable "ami" {
    description = "EC2 AMI ID"
    default = "ami-01b799c439fd5516a"
  
}

variable "instance_name" {
    description = "The name of the instance"
    type = string
  
}