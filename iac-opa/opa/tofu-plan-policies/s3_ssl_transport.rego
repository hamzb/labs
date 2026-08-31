package terraform.compliance.s3

import rego.v1

# AWS-S3-004
# S3 buckets must deny requests made over non-SSL transport.
violations contains violation if {
	bucket := s3_buckets[_]
	not denies_non_ssl_transport(bucket)

	violation := {
		"policy_id": "AWS-S3-004",
		"severity": "high",
		"resource": bucket.address,
		"message": "S3 buckets must deny non-SSL requests.",
		"remediation": "Attach an aws_s3_bucket_policy with a Deny statement where the condition Bool aws:SecureTransport is false.",
	}
}

denies_non_ssl_transport(bucket) if {
	bucket_policy := managed_resources[_]
	bucket_policy.type == "aws_s3_bucket_policy"
	module_address(bucket_policy.address) == module_address(bucket.address)

	policy := json.unmarshal(bucket_policy.values.policy)
	statement := policy.Statement[_]

	statement.Effect == "Deny"
	statement_applies_to_s3(statement)
	condition_denies_insecure_transport(statement.Condition)
}

statement_applies_to_s3(statement) if {
	statement.Action == "s3:*"
}

statement_applies_to_s3(statement) if {
	statement.Action[_] == "s3:*"
}

condition_denies_insecure_transport(condition) if {
	lower(condition.Bool["aws:SecureTransport"]) == "false"
}
