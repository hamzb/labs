bucket_public_access_block = {
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

bucket_versioning_enabled = true

bucket_encryption = {
  enabled            = true
  sse_algorithm      = "aws:kms"
  kms_key_id         = "arn:aws:kms:eu-central-1:000000000000:key/customer-documents-lab"
  bucket_key_enabled = true
}

bucket_deny_insecure_transport = true
