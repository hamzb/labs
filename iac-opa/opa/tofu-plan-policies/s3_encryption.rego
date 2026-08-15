package terraform.compliance.s3

import rego.v1

# AWS-S3-003
# S3 buckets must use SSE-KMS with a customer managed KMS key.
violations contains violation if {
	bucket := s3_buckets[_]
	not has_cmk_encryption(bucket)

	violation := {
		"policy_id": "AWS-S3-003",
		"severity": "critical",
		"resource": bucket.address,
		"message": "S3 buckets must use SSE-KMS with a customer managed KMS key.",
		"remediation": "Configure S3 default encryption with sse_algorithm set to aws:kms or aws:kms:dsse and kms_master_key_id set to a customer managed KMS key.",
	}
}

has_cmk_encryption(bucket) if {
	encryption_config_uses_cmk(object.get(bucket.values, "server_side_encryption_configuration", []))
}

has_cmk_encryption(bucket) if {
	encryption := managed_resources[_]
	encryption.type == "aws_s3_bucket_server_side_encryption_configuration"
	module_address(encryption.address) == module_address(bucket.address)

	encryption_rules_use_cmk(object.get(encryption.values, "rule", []))
}

encryption_config_uses_cmk(configs) if {
	config := configs[_]
	encryption_rules_use_cmk(object.get(config, "rule", []))
}

encryption_rules_use_cmk(rules) if {
	rule := rules[_]
	defaults := object.get(rule, "apply_server_side_encryption_by_default", [])
	encryption_default := defaults[_]

	kms_s3_algorithm(object.get(encryption_default, "sse_algorithm", ""))
	customer_managed_kms_key(object.get(encryption_default, "kms_master_key_id", ""))
}

kms_s3_algorithm(algorithm) if {
	algorithm == "aws:kms"
}

kms_s3_algorithm(algorithm) if {
	algorithm == "aws:kms:dsse"
}

customer_managed_kms_key(key_id) if {
	key_id != ""
	lower(key_id) != "alias/aws/s3"
	not endswith(lower(key_id), ":alias/aws/s3")
}
