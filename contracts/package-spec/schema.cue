package package_spec

import "github.com/insuperposition/firmament/contracts/layout"

// A pin names one exact artifact. Every pin in every contract has this
// shape: the scheme of source gives its type (oci://, https://), version is
// what a person reads, and digest is what is fetched.
#Pin: {
	source!:  =~"^[a-z][a-z0-9+.-]*://[^[:space:]]+$"
	version!: string & !=""
	digest!:  =~"^sha256:[a-f0-9]{64}$"
}

// A capability is what a package or cluster needs or offers, such as cni
// or certificates. It is vocabulary, never a cluster or environment name.
#CapabilityName: =~"^[a-z][a-z0-9-]*$"

// A requirement names a capability. With scope cluster (the default) a
// package of the same cluster provides it; with scope mesh another cluster
// of the environment does.
#Requirement: {
	name!: #CapabilityName
	scope: *"cluster" | "mesh"
}

// A provider states how its readiness is checked, so ordering by
// requirement means the provider is ready, not merely created.
#Provision: {
	name!: #CapabilityName
	ready!: {
		kind!:      =~"^[A-Z][A-Za-z0-9]*$"
		name!:      layout.#Name
		namespace?: layout.#Name
	}
}

// package.yaml
#Package: {
	name!:      layout.#PackageName
	layer!:     =~"^[a-z][a-z0-9]*$"
	source!:    #Pin
	namespace!: layout.#Name
	requires: [...#Requirement]
	provides: [...#Provision]
	bootstrap: *false | bool
	// Values keys an environment delta may set; any other key is refused.
	delta_keys: [...string]
	// Path of the package's values schema, relative to the package folder.
	values_schema?: =~"^[^/][^[:space:]]*$"

	// The layer is the name's prefix: cni-cilium is in layer cni.
	_nameStartsWithLayer: name & =~"^\(layer)-"
}
