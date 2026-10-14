package runrecord

// The run record: what one run of the tour observed. Each action keeps the
// time, the command, its exit status, the tested reference, the controls that
// made the check meaningful and what the cluster answered. The record is
// plain data the tour writes and the evidence task reads.
//
// Closed: a field not declared here is refused. contracts:lint checks the
// sample against #Contract; the tour and the evidence task check the records
// they write and read against the same fields. A record that is not complete
// is never published.
#Contract: #RunRecord

#Time: =~"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"

#Revision: =~"^[0-9a-f]{40}$"

// What stands in place of a line that names an address or a pod.
#Marker: "[line withheld: names an address or a pod]"

// A line is kept only when it carries one of the known refusal phrases and
// names no address and no pod: no dotted IPv4, no IPv6 group, no name with
// three or more dash-separated parts. A line that fails any of these is
// stored as the marker instead.
#Phrase: =~"(must be signed by the signer|PodSecurity|ephemeral containers are not allowed|no matching CertificateIdentity|no signatures found)"

#Names: !~"[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+" & !~"[0-9A-Fa-f]*:[0-9A-Fa-f]*:[0-9A-Fa-f]*" & !~"[a-z0-9]+(-[a-z0-9]+){2,}"

#Line: #Marker | (=~"^.{1,300}$" & #Phrase & #Names)

#Guarantee: "wrong-signer-chart-refused" | "direct-access-denied-gateway-allowed" | "unsigned-image-refused"

// The reference an action tested, and whether it is a tag or a digest.
#Reference: close({
	kind!:  "tag" | "digest"
	value!: string & !=""
})

// A control makes a negative check meaningful: the matching case that must
// succeed, or the untouched namespace that must be left alone.
#Control: close({
	name!:   string & !=""
	passed!: bool
})

#Observation: close({
	kind!: "refusal" | "condition"
	line!: #Line
}) | close({
	kind!:           "flow"
	verdict!:        "FORWARDED" | "DROPPED"
	count!:          int & >=0
	window_seconds!: int & >0
}) | close({
	kind!:   "http"
	status!: int & >=100 & <=599
})

// What a selector prints as one JSON object on its last line of output.
_result: {
	guarantee!:   #Guarantee
	command!:     string & !=""
	exit_status!: int & >=0
	reference?:   #Reference
	controls!: [#Control, ...#Control]
	observations!: [#Observation, ...#Observation]
}

#SelectorResult: close(_result)

#Action: close(_result & {
	started!:  #Time
	finished!: #Time
})

_record: {
	schema!:   1
	started!:  #Time
	finished?: #Time
	// The revision the checkout is at and the revision the cluster runs.
	revision!: close({
		checkout!: #Revision
		cluster!:  #Revision
		matches!:  bool
	})
	complete!: bool
	actions!: [...#Action]
}

// A complete record holds the three guarantees in order, each with an exit
// status of zero and every control passed. An incomplete record holds
// whatever ran before the failure and is never published.
#RunRecord: close(_record) & ({
	complete: true
	finished: #Time
	actions: [
		{guarantee: "wrong-signer-chart-refused", ...},
		{guarantee: "direct-access-denied-gateway-allowed", ...},
		{guarantee: "unsigned-image-refused", ...},
	]
	actions: [...{exit_status: 0, controls: [...{passed: true, ...}], ...}]
} | {
	complete: false
})
