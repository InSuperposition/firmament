package privatestate

// The private-state manifest: which secret files a build keeps in the
// environment's private state directory, and the mode each one must have.
// The manifest holds no secret; the files it names sit beside it.
// Closed: a field not declared here is refused. contracts:lint checks the
// sample against #Contract, and the tasks that write or read the manifest
// check it against the same fields.
#Contract: #PrivateState

// A file name beside the manifest: no directory part.
#FileName: =~"^[A-Za-z0-9][A-Za-z0-9._-]*$"

// A key or token: readable by its owner only.
#Secret: close({
	path!: #FileName
	mode!: "0600"
})

// A certificate holds no secret; it may be world-readable.
#Certificate: close({
	path!: #FileName
	mode!: "0600" | "0644"
})

// A Raft snapshot of OpenBao and the SHA-256 of the root certificate it holds,
// as lowercase hex. Optional: it exists only after a first snapshot.
#Snapshot: close({
	path!:             #FileName
	mode!:             "0600"
	root_fingerprint!: =~"^[0-9a-f]{64}$"
})

#PrivateState: close({
	openbao!: close({
		// The static seal key: 32 random bytes in a binary file (C39).
		seal_key!: #Secret
		// The CA whose certificates may log in to OpenBao as an operator (C89).
		operator_ca!: close({
			certificate!: #Certificate
			key!:         #Secret
		})
		// One client certificate signed by that CA.
		operator_client!: close({
			certificate!: #Certificate
			key!:         #Secret
		})
		// The newest snapshot, and the one before it (kept so one bad save
		// cannot erase the only good copy). Restore reads the newest only.
		snapshot?:          #Snapshot
		snapshot_previous?: #Snapshot
	})
})
