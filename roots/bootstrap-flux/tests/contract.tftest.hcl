# The cluster-access contract is checked where this root reads it. The
# fixtures hold the file the Kubernetes root writes, with one value planted
# per run.
run "accepts_the_cluster_access_contract" {
  command = plan

  variables {
    state_directory = "tests/fixtures/valid"
  }
}

run "rejects_an_integer_api_port_naming_the_field" {
  command = plan

  variables {
    state_directory = "tests/fixtures/port-as-integer"
  }

  expect_failures = [terraform_data.cluster_access_contract]
}

run "rejects_a_missing_datapath_mode_naming_the_field" {
  command = plan

  variables {
    state_directory = "tests/fixtures/missing-datapath"
  }

  expect_failures = [terraform_data.cluster_access_contract]
}

run "rejects_a_short_git_commit_naming_the_field" {
  command = plan

  variables {
    state_directory = "tests/fixtures/short-git-commit"
  }

  expect_failures = [terraform_data.cluster_access_contract]
}

run "rejects_a_missing_git_commit_naming_the_field" {
  command = plan

  variables {
    state_directory = "tests/fixtures/missing-git-commit"
  }

  expect_failures = [terraform_data.cluster_access_contract]
}
