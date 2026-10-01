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
