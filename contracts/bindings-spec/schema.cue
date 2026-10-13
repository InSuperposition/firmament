package bindingsspec

// The packages.yaml format: a list of bindings, each placing one package in
// a namespace for a tenant. Closed: a binding without a tenant is refused. A
// binding is active unless it says retired: a retired binding keeps its
// namespace, quota and network policy but stops installing its chart.
// Whether the package and the tenant exist is a cross-file rule that the
// modules consuming the bindings check. contracts:lint checks the sample
// against #Contract.
#Contract: [...#Binding]

#Name: =~"^[a-z][a-z0-9-]*$"

#Binding: close({
	package!:   #Name
	namespace!: #Name
	tenant!:    #Name
	retired?:   true
})
