variables {
  state_directory = "/tmp/firmament-test"
  git_branch      = "feature/test"
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

run "rejects_a_branch_git_would_refuse" {
  command = plan

  variables {
    git_branch = "feature..x"
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
