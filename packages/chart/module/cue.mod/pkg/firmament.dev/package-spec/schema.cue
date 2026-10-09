package packagespec

// The package.yaml format: what one package is, what it requires and
// provides, and which delta keys it accepts. Closed: a field not declared
// here is refused, and a namespace is not a field because bindings place a
// package (C70). contracts:lint checks the sample against #Contract.
#Contract: #Package

#Name: =~"^[a-z][a-z0-9-]*$"

#Package: close({
	name!:  #Name
	layer!: #Name
	pin!: close({
		source!:  string & !=""
		version!: string & !=""
		digest!:  =~"^sha256:[a-f0-9]{64}$"
	})
	bootstrap?: bool
	// Keys an environment delta may set; a delta naming another key is refused.
	delta_keys?: [...string & !=""]
	requires?: [...#Requirement]
	provides?: [...#Provision]
})

#Scope: "cluster" | "mesh"

#Requirement: close({
	capability!: #Name
	scope!:      #Scope
})

#Provision: close({
	capability!: #Name
	scope!:      #Scope
	port!:       int & >=1 & <=65535
	protocol!:   "TCP" | "UDP"
	readiness!: close({
		kind!: string & !=""
		name!: string & !=""
	})
})
