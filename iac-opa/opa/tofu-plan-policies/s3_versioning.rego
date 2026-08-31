package terraform.compliance.s3

import rego.v1

# AWS-S3-002
# S3 buckets must have versioning enabled.
violations contains violation if {
	bucket := s3_buckets[_]
	not has_versioning_enabled(bucket)

	violation := {
		"policy_id": "AWS-S3-002",
		"severity": "high",
		"resource": bucket.address,
		"message": "S3 buckets must have versioning enabled.",
		"remediation": "Enable S3 bucket versioning for the bucket, either directly on aws_s3_bucket or with aws_s3_bucket_versioning.",
	}
}

has_versioning_enabled(bucket) if {
	versioning := object.get(bucket.values, "versioning", [])[_]
	object.get(versioning, "enabled", false) == true
}

has_versioning_enabled(bucket) if {
	versioning := managed_resources[_]
	versioning.type == "aws_s3_bucket_versioning"
	module_address(versioning.address) == module_address(bucket.address)

	config := object.get(versioning.values, "versioning_configuration", [])[_]
	object.get(config, "status", "") == "Enabled"
}
