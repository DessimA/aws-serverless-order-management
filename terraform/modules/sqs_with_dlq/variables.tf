variable "queue_name" {
  type = string
}

variable "dlq_name" {
  type = string
}

variable "is_fifo" {
  type    = bool
  default = false
}

variable "content_based_deduplication" {
  type    = bool
  default = false
}

variable "visibility_timeout" {
  type    = number
  default = 360
}

variable "sns_topic_arn" {
  type = string
}

variable "alarm_name" {
  type = string
}
