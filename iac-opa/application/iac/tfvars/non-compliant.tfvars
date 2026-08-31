bucket_public_access_block = {
  block_public_acls       = false
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

bucket_versioning_enabled = false

bucket_encryption = {
  enabled            = true
  sse_algorithm      = "AES256"
  kms_key_id         = null
  bucket_key_enabled = false
}

bucket_deny_insecure_transport = false
