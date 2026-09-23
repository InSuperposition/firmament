terraform {
  required_version = ">= 1.12.0"

  required_providers {
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
  }
}

data "external" "readiness" {
  program = ["bash", "${path.module}/scripts/probe.sh"]

  query = {
    target        = var.ssh_target
    port          = var.ssh_port == null ? "" : tostring(var.ssh_port)
    identity_file = var.ssh_identity_file == null ? "" : var.ssh_identity_file
  }

  lifecycle {
    postcondition {
      condition     = self.result.id == "ubuntu"
      error_message = "Host is not Ubuntu."
    }
    postcondition {
      condition     = self.result.version_id == "26.04"
      error_message = "Ubuntu 26.04 is required."
    }
    postcondition {
      condition     = contains(["aarch64", "arm64", "x86_64"], self.result.arch)
      error_message = "Unsupported host architecture."
    }
    postcondition {
      condition     = self.result.init == "systemd"
      error_message = "systemd is required as PID 1."
    }
    postcondition {
      condition     = self.result.cgroup == "cgroup2fs"
      error_message = "cgroup v2 is required."
    }
    postcondition {
      condition     = self.result.btf == "present"
      error_message = "Kernel BTF is required."
    }
    postcondition {
      condition     = self.result.sudo == "available"
      error_message = "Passwordless sudo is required."
    }
    postcondition {
      condition     = self.result.command_curl == "present"
      error_message = "curl is required on the host."
    }
    postcondition {
      condition     = self.result.command_systemctl == "present"
      error_message = "systemctl is required on the host."
    }
  }
}
