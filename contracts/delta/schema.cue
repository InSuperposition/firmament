package deltaspec

// The environments/<env>/deltas/<cluster>/<package>.yaml format: a sparse
// divergence from the cluster's values, with the reason for it. Closed. The
// keys in values must be keys the package declares in delta_keys; that rule
// spans two files, so the module consuming the delta checks it.
// contracts:lint checks the sample against #Contract.
#Contract: #Delta

#Delta: close({
	reason!: string & !=""
	values!: {[string & !=""]: _}
})
