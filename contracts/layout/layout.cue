package layout

// Schema of layout.yaml. mise run layout:lint validates the data with it
// before applying any rule.

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

folders: {[#FolderName]: #Folder}
package_pattern: string & !=""
code_extensions: [...=~"^[a-z0-9]+$"]
data_extensions: [...=~"^[a-z0-9]+$"]
cluster_name_places: [...#Place] & [_, ...]
fact_patterns: [...{name: string & !="", regex: string & !=""}]
fact_allow: [...string]
exceptions: [...{
	rule:  #Rule
	paths: [string, ...string]
	owners: [string, ...string]
	reason: string & !=""
}]
