package private_state

import "list"

// The files in an environment's private state directory
// ($FIRMAMENT_STATE_HOME/environments/<env>/), each under the name other
// contracts use to refer to it. Secrets and credentials live only there,
// never in the repository; this contract lists them and holds no value.
#PrivateState: {
	files!: [=~"^[a-z][a-z0-9-]*$"]: {
		// Relative to the private state directory.
		path!: =~"^[^/][^[:space:]]*$"
		// Readable by the operator only.
		mode: "0600"
		// The task or item that writes the file.
		producer!: string & !=""
		consumers!: [string & !="", ...string & !=""]
		// When and how the file is replaced.
		rotation!: string & !=""
		// Another file this one is useless without, such as the seal key a
		// Raft snapshot was taken under.
		needs?: [...=~"^[a-z][a-z0-9-]*$"]
	}
	// Every file another file needs is listed here. A missing one fails as
	// _neededFileIsListed.<name>: conflicting values true and false.
	_names: [for n, _ in files {n}]
	for _, f in files if f.needs != _|_ for n in f.needs {
		_neededFileIsListed: (n): true & list.Contains(_names, n)
	}
}
