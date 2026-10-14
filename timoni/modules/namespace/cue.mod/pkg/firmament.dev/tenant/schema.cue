package tenantspec

// The environments/<env>/tenants/<name>.yaml format. Closed. The kind
// cluster is reserved for a later enrolled cluster and is not accepted yet
// (C72). contracts:lint checks the sample against #Contract.
#Contract: #Tenant

#Quantity: =~"^[0-9]+(\\.[0-9]+)?(m|Ki|Mi|Gi|Ti)?$"

#Tenant: close({
	kind!: "platform" | "team" | "customer"
	namespace_quota!: close({
		cpu!:    #Quantity
		memory!: #Quantity
	})
	administrators!: [...string & !=""]
})
