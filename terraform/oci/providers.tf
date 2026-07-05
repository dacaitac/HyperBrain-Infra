terraform {
  required_version = ">= 1.7"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 6.0"
    }
  }
  # Local backend — terraform.tfstate is gitignored.
  # Encrypted backup: sops --encrypt --age <PUBLIC_KEY> terraform.tfstate > terraform.tfstate.enc
  backend "local" {}
}

provider "oci" {
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = var.private_key_path
  region           = var.region
}
