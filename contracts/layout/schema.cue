package layout

// Schema of layout.yaml. mise run layout:lint validates the data with it
// before applying any rule. The name types below are shared: other
// contracts import them, so every contract accepts the same names.

// A cluster, environment, tenant or machine name: a DNS-1123 label, so it
// can be a Kubernetes object name, a machine name and a path segment.
#Name: =~"^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$"

// A package folder name is <layer>-<tool>.
#PackageNamePattern: "^[a-z][a-z0-9]*-[a-z0-9][a-z0-9-]*$"
#PackageName:        =~#PackageNamePattern

#Folder: {
	holds: string & !=""
	may_reference: [...#FolderName]
}

#FolderName: "contracts" | "packages" | "engines" | "orchestrators" | "modules" | "roots" | "clusters" | "environments"

#Place: {
	description: string & !=""
	path?:       string & !=""
	value?:      string & !=""
}

#Rule: "environments-no-code" | "no-names" | "no-facts" | "packages-not-executable" | "task-folder-pairs-package" | "modules-no-references" | "roots-no-names"

// Which contract, and which definition in it, a data file must satisfy.
#ContractFile: {
	glob!:       string & !=""
	contract!:   =~"^[a-z][a-z0-9-]*$"
	definition!: =~"^#[A-Z][A-Za-z]*$"
}

folders: {[#FolderName]: #Folder}
package_pattern: #PackageNamePattern
code_extensions: [...=~"^[a-z0-9]+$"]
data_extensions: [...=~"^[a-z0-9]+$"]
cluster_name_places: [...#Place] & [_, ...]
fact_patterns: [...{name: string & !="", regex: string & !=""}]
fact_allow: [...string]
exceptions: [...{
	rule: #Rule
	paths: [string, ...string]
	owners: [string, ...string]
	reason: string & !=""
}]
contract_files: [...#ContractFile]
