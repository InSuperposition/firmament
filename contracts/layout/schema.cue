package layout

// The layout contract. Closed: a folder, field or check not declared here
// is refused. contracts:lint checks the data against #Contract.
#Contract: #Layout

#Folder: close({
	holds!:         string & !=""
	may_reference!: [...#FolderName]
	must_never!:    [...string & !=""]
})

#FolderName: "contracts" | "packages" | "modules" | "roots" | "clusters" | "environments"

#Layout: close({
	folders!: close({[#FolderName]: #Folder}) & {
		contracts!:    _
		packages!:     _
		modules!:      _
		roots!:        _
		clusters!:     _
		environments!: _
	}
	cluster_name_places!: [_, ...string & !=""]
	reference_notes?: [...string & !=""]
	standalone_checks!: [...close({rule!: string & !="", task!: =~"^[a-z0-9-]+:[a-z]+$"})]
	review_checks!: [_, ...string & !=""]
})
