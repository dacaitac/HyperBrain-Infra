# ── Locals ────────────────────────────────────────────────────────────────────

locals {
  common_tags = {
    project    = "hyperbrain"
    managed_by = "terraform"
  }
}

# ── VCN ───────────────────────────────────────────────────────────────────────

resource "oci_core_vcn" "main" {
  compartment_id = var.compartment_id
  cidr_block     = var.vcn_cidr
  display_name   = "hyperbrain-vcn"
  dns_label      = "hyperbrain"

  freeform_tags = local.common_tags
}

# ── Internet Gateway ──────────────────────────────────────────────────────────

resource "oci_core_internet_gateway" "main" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "hyperbrain-igw"
  enabled        = true

  freeform_tags = local.common_tags
}

# ── Route Table ───────────────────────────────────────────────────────────────

resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "hyperbrain-public-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.main.id
  }

  freeform_tags = local.common_tags
}

# ── Security List ─────────────────────────────────────────────────────────────
# Monitoring ports (3000, 9090, 9100) restricted to Tailscale CGNAT range.
# SSH and Tailscale handshake are open to 0.0.0.0/0.
# Additional hardening (OCI WAF, fail2ban on the instance) is out of Terraform scope.

resource "oci_core_security_list" "main" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "hyperbrain-sl"

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
    description = "Allow all outbound"
  }

  # SSH — provisioning and day-to-day operations
  ingress_security_rules {
    protocol    = "6" # TCP
    source      = "0.0.0.0/0"
    description = "SSH"
    tcp_options {
      min = 22
      max = 22
    }
  }

  # Tailscale — UDP 41641 for direct peer-to-peer connections (falls back to DERP over 443)
  ingress_security_rules {
    protocol    = "17" # UDP
    source      = "0.0.0.0/0"
    description = "Tailscale direct"
    udp_options {
      min = 41641
      max = 41641
    }
  }

  # Grafana — Tailscale CGNAT range only (100.64.0.0/10)
  ingress_security_rules {
    protocol    = "6"
    source      = "100.64.0.0/10"
    description = "Grafana (Tailscale only)"
    tcp_options {
      min = 3000
      max = 3000
    }
  }

  # Prometheus — Tailscale CGNAT range only
  ingress_security_rules {
    protocol    = "6"
    source      = "100.64.0.0/10"
    description = "Prometheus (Tailscale only)"
    tcp_options {
      min = 9090
      max = 9090
    }
  }

  # node-exporter — Tailscale CGNAT range only
  ingress_security_rules {
    protocol    = "6"
    source      = "100.64.0.0/10"
    description = "node-exporter (Tailscale only)"
    tcp_options {
      min = 9100
      max = 9100
    }
  }

  freeform_tags = local.common_tags
}

# ── Public Subnet ─────────────────────────────────────────────────────────────

resource "oci_core_subnet" "public" {
  compartment_id    = var.compartment_id
  vcn_id            = oci_core_vcn.main.id
  cidr_block        = var.subnet_cidr
  display_name      = "hyperbrain-public-subnet"
  dns_label         = "public"
  route_table_id    = oci_core_route_table.public.id
  security_list_ids = [oci_core_security_list.main.id]

  freeform_tags = local.common_tags
}
