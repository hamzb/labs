package terraform.compliance.s3

import rego.v1

default allow := false

allow if {
	count(violations) == 0
}

decision := {
	"allow": allow,
	"violations": violations,
}

s3_buckets contains bucket if {
	bucket := managed_resources[_]
	bucket.type == "aws_s3_bucket"
}

# planned_values represents the proposed final configuration. walk() lets the
# policy find managed resources in both the root module and nested child_modules.
managed_resources contains resource if {
	[_, resource] := walk(input.planned_values.root_module)
	is_object(resource)
	object.get(resource, "mode", "") == "managed"
	object.get(resource, "address", "") != ""
	object.get(resource, "type", "") != ""
	is_object(object.get(resource, "values", null))
}

# A Terraform resource address ends in <resource_type>.<resource_name>.
# Removing those two segments produces the containing module address. This
# supports root resources as well as arbitrarily nested modules.
module_address(address) := concat(".", array.slice(parts, 0, count(parts) - 2)) if {
	parts := split(address, ".")
}
