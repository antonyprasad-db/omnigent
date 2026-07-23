output "artifact_bucket" {
  description = "S3 bucket for the image build context — upload omnigent-host-microvm.zip here."
  value       = aws_s3_bucket.artifacts.bucket
}

output "build_role_arn" {
  description = "Pass as --build-role-arn / buildRoleArn to create-microvm-image."
  value       = aws_iam_role.build.arn
}

output "execution_role_arn" {
  description = "Set as sandbox.lambda_microvm.execution_role_arn in the server config."
  value       = aws_iam_role.exec.arn
}

output "operator_role_arn" {
  description = "Assume this to drive the control plane (build image, run MicroVMs)."
  value       = aws_iam_role.operator.arn
}

output "connector_operator_role_arn" {
  description = "Operator role for the VPC egress connector (null when the connector is disabled)."
  value       = var.enable_vpc_egress_connector ? aws_iam_role.connector_operator[0].arn : null
}

output "next_steps" {
  description = "What to do after apply."
  value       = <<-EOT
    1. Upload the build context:
       (cd .. && zip -j /tmp/omnigent-host-microvm.zip Dockerfile hooks_server.py entrypoint.sh start_host.sh)
       aws s3 cp /tmp/omnigent-host-microvm.zip s3://${aws_s3_bucket.artifacts.bucket}/omnigent-host-microvm.zip
    2. Build the image (hooks ENABLED):
       ACCOUNT_ID=${local.account_id} REGION=${var.region} ARTIFACT_BUCKET=${aws_s3_bucket.artifacts.bucket} python ../build_image.py
    3. Configure the server (see ../RUNBOOK-live-validation.md), then run e2e_managed.py.
  EOT
}
