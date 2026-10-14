import "strings"

// What the Flux source of a cluster must say about the artifact it applies.
// flux-refs:lint passes the repository (owner/name as the origin remote spells
// it) and the file name of the publish workflow, and vets each OCIRepository
// and each environment.yaml against these definitions.
repository: string @tag(repository)
workflow:   string @tag(workflow)

_repositoryPattern: strings.Replace(repository, ".", "\\.", -1)
_workflowPattern:   strings.Replace(workflow, ".", "\\.", -1)

// Each field is required (!): a definition alone would fill in a missing one.
// The keyless identity of the publish workflow on a branch of this repository.
#OCIRepository: {
	spec!: {
		url!: "oci://${artifact_source}"
		ref!: tag!: "${git_commit}"
		verify!: {
			provider: "cosign"
			matchOIDCIdentity: [{
				issuer:  "^https://token\\.actions\\.githubusercontent\\.com$"
				subject: "^https://github\\.com/\(_repositoryPattern)/\\.github/workflows/\(_workflowPattern)@refs/heads/.+$"
			}]
		}
		...
	}
	...
}

// The registry path is the repository's name in lowercase.
#Environment: {
	artifact_source!: "ghcr.io/\(strings.ToLower(repository))"
	...
}
