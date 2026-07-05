output "instance_public_ip" {
  description = "Public IP of the OCI compute instance — use this for initial SSH and to register on Tailscale"
  value       = oci_core_instance.hyperbrain.public_ip
}

output "instance_ocid" {
  description = "OCID of the provisioned compute instance"
  value       = oci_core_instance.hyperbrain.id
}

output "availability_domain" {
  description = "Availability domain where the instance was provisioned"
  value       = oci_core_instance.hyperbrain.availability_domain
}

output "ubuntu_image_name" {
  description = "Ubuntu 22.04 ARM64 image selected for the instance"
  value       = data.oci_core_images.ubuntu_22_arm.images[0].display_name
}

output "ssh_command" {
  description = "SSH command to connect to the instance (replace key path as needed)"
  value       = "ssh ubuntu@${oci_core_instance.hyperbrain.public_ip}"
}
