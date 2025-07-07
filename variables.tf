variable "instance_type" {
description = "value"
type = string
default = "t2.micro"

}

variable "ami" {
type = string
default = "ami-01b799c439fd5516a"
}

variable "instance_name" {
type = string
default = "web-instance-2"
}