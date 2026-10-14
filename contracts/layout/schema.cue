package layout

// The layout contract. Closed: a folder, field or check not declared here
// is refused. contracts:lint checks the data against #Contract. That the
// folders match the tracked tree, the README block and the packages is
// checked by layout:lint, which reads the tree.
#Contract: #Layout

// A top-level folder name; a dot folder such as .mise is allowed.
#FolderName: =~"^\\.?[a-z][a-z0-9.-]*$"

// One line of prose that renders into a Markdown table cell.
#Cell: string & =~"^[^|\n]+$"

#Folder: close({
	holds!:         #Cell
	may_reference!: [...#FolderName]
	must_never!:    [...string & !=""]
})

// What a kind of directory under packages/ is. The kind of a directory is
// detected from the tracked tree by layout:lint, never listed here.
#PackageKind: close({
	holds!: #Cell
})

#Layout: close({
	folders!:         close({[#FolderName]: #Folder})
	top_level_files!: close({holds!: #Cell})
	package_kinds!: close({
		"flux-package"!:  #PackageKind
		"render-module"!: #PackageKind
		"manifest-only"!: #PackageKind
	})
	// Where to look for a task; each path must be in the tracked tree.
	find!: [_, ...close({
		question!: #Cell
		path!:     string & =~"^[^|\n]+$"
	})]
	cluster_name_places!: [_, ...string & !=""]
	reference_notes?: [...string & !=""]
	standalone_checks!: [...close({rule!: string & !="", task!: =~"^[a-z0-9-]+:[a-z]+$"})]
	review_checks!: [_, ...string & !=""]
})
