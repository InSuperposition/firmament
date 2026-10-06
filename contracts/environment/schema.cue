package environment

// The environment contract: the facts an environment states about itself.
// Closed, so each later fact needs a schema edit.
#Contract: #Environment

#Environment: close({
	cluster!: string & =~"^[a-z][a-z0-9-]*$"
})
