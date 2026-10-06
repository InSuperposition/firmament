# The fixtures directory holds a machine-hosts contract, as the machine
# root writes it.
variables {
  state_directory = "tests/fixtures"
  git_branch      = "feature/test"
  environment     = "local"
}

run "accepts_a_branch_with_slashes_dots_and_dashes" {
  command = plan

  variables {
    git_branch = "feat/flux-bootstrap_2.x"
  }
}

run "rejects_a_branch_with_shell_characters" {
  command = plan

  variables {
    git_branch = "main;touch /tmp/owned"
  }

  expect_failures = [var.git_branch]
}

run "rejects_a_branch_with_command_substitution" {
  command = plan

  variables {
    git_branch = "$(id)"
  }

  expect_failures = [var.git_branch]
}

run "rejects_a_branch_that_looks_like_an_option" {
  command = plan

  variables {
    git_branch = "-x"
  }

  expect_failures = [var.git_branch]
}

run "rejects_an_environment_name_with_uppercase_or_slashes" {
  command = plan

  variables {
    environment = "Local/../x"
  }

  expect_failures = [var.environment]
}

run "accepts_the_machine_hosts_and_environment_contracts" {
  command = plan
}

run "rejects_a_string_ssh_port_naming_the_field" {
  command = plan

  variables {
    state_directory = "tests/fixtures/port-as-string"
  }

  expect_failures = [terraform_data.machine_hosts_contract]
}

run "rejects_a_malformed_ssh_host_key_naming_the_field" {
  command = plan

  variables {
    state_directory = "tests/fixtures/bad-host-key"
  }

  expect_failures = [terraform_data.machine_hosts_contract]
}

run "rejects_an_uppercase_cluster_naming_the_field" {
  command = plan

  variables {
    environment            = "uppercase-cluster"
    environments_directory = "tests/fixtures/environments"
  }

  expect_failures = [terraform_data.environment_contract]
}

run "rejects_a_field_the_environment_schema_does_not_declare" {
  command = plan

  variables {
    environment            = "extra-field"
    environments_directory = "tests/fixtures/environments"
  }

  expect_failures = [terraform_data.environment_contract]
}

run "rejects_an_environment_without_artifact_source_naming_the_field" {
  command = plan

  variables {
    environment            = "no-artifact-source"
    environments_directory = "tests/fixtures/environments"
  }

  expect_failures = [terraform_data.environment_contract]
}
