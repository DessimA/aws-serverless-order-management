variable "aws_region" {
  type = string
}

variable "resource_suffix" {
  type = string
}

variable "notification_email" {
  type    = string
  default = ""
}

variable "deploy_target" {
  type    = string
  default = "localstack"

  validation {
    condition     = contains(["aws", "localstack"], var.deploy_target)
    error_message = "deploy_target must be either 'aws' or 'localstack'."
  }
}

variable "allowed_source_ip" {
  type    = string
  default = ""
}
