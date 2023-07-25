variable "project" {
  type = string
}
variable "env" {
  type = string
}
variable "aws_profile" {
  type = string
}
variable "aws_region" {
  type = string
}
variable "zone_name" {
  type = string
}
variable "tags" {
  type = map(string)
}