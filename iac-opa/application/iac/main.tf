module "customer_documents" {
  source = "../../modules/secure-bucket"

  bucket_name = "customer-document-processing-lab"
  tags = {
    owner               = "document-platform"
    environment         = "local"
    data_classification = "confidential"
    managed_by          = "opentofu"
  }

  public_access_block     = var.bucket_public_access_block
  versioning_enabled      = var.bucket_versioning_enabled
  encryption              = var.bucket_encryption
  deny_insecure_transport = var.bucket_deny_insecure_transport
}
