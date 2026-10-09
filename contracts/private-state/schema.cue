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

#PrivateState: close({
	openbao!: close({
		// The static seal key: 32 random bytes, base64-encoded (C39).
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
	})
})
