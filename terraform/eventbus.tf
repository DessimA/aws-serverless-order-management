resource "aws_cloudwatch_event_bus" "main" {
  name = local.event_bus_name
}
