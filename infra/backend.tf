# backend.tf

terraform {
  backend "s3" {
    bucket         = "tf-readme-generator-state-jh98hl4p"
    key            = "global/s3/terraform.tfstate"
    region         = "us-west-2"
    dynamodb_table = "readme-generator-tf-locks"
  }
}
