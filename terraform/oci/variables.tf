# ── OCI Authentication ─────────────────────────────────────────────────────────

variable "tenancy_ocid" {
  description = "OCID of the OCI tenancy"
  type        = string
  sensitive   = true
}

variable "user_ocid" {
  description = "OCID of the OCI user (API key owner)"
  type        = string
  sensitive   = true
}

variable "fingerprint" {
  description = "Fingerprint of the OCI API key pair"
  type        = string
  sensitive   = true
}

variable "private_key_path" {
  description = "Absolute path to the OCI API private key PEM file on the local machine"
  type        = string
}

# ── OCI Location ───────────────────────────────────────────────────────────────

variable "region" {
  description = "OCI region identifier"
  type        = string
  default     = "us-ashburn-1"
}

variable "compartment_id" {
  description = "OCID of the compartment where all resources will be created"
  type        = string
}

variable "ad_index" {
  description = "Availability domain index (0-based). Change to 1 or 2 if A1.Flex capacity is exhausted."
  type        = number
  default     = 0
}

# ── Instance ───────────────────────────────────────────────────────────────────

variable "instance_name" {
  description = "Display name for the compute instance"
  type        = string
  default     = "hyperbrain-oci"
}

variable "ocpus" {
  description = "Number of OCPUs for VM.Standard.A1.Flex (free tier: max 4 total across all A1 instances)"
  type        = number
  default     = 2
}

variable "memory_in_gbs" {
  description = "Memory in GB for VM.Standard.A1.Flex (free tier: max 24 GB total)"
  type        = number
  default     = 12
}

variable "boot_volume_size_in_gbs" {
  description = "Boot volume size in GB (free tier: up to 200 GB total for all boot volumes)"
  type        = number
  default     = 50
}

variable "ssh_public_key" {
  description = "SSH public key content to install on the instance (e.g. output of: cat ~/.ssh/id_ed25519.pub)"
  type        = string
  sensitive   = true
}

# ── Networking ─────────────────────────────────────────────────────────────────

variable "vcn_cidr" {
  description = "CIDR block for the VCN"
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR block for the public subnet"
  type        = string
  default     = "10.0.1.0/24"
}
