# Terraform module — `lambda_microvm` provider prerequisites

Declarative equivalent of `../setup.sh`: provisions the AWS-side resources the
`lambda_microvm` sandbox provider needs, so a team can review and manage them in
version control instead of running a shell script.

## What it creates

- **S3 artifact bucket** (public access blocked) for the image build context.
- **Build role** — assumed by Lambda during `create-microvm-image`. Trust allows
  `sts:AssumeRole` **and** `sts:TagSession` (the build fails without the latter).
- **Execution role** — assumed by the running MicroVM; CloudWatch Logs +
  `bedrock:InvokeModel` for the key-free model path.
- **Operator role** — for the principal that drives the control plane. Note the
  IAM action namespace is `lambda:`, not `lambda-microvms:`.
- **(optional) VPC egress connector** + its operator role — see below.

## Usage

```hcl
module "microvm" {
  source      = "./terraform"
  region      = "us-east-1"
  name_prefix = "omnigent-microvm"
}
```

```bash
terraform init
terraform apply
# then follow the `next_steps` output: upload build context → build image → run.
```

The image build itself (`../build_image.py`) is intentionally **not** in
Terraform — it's an imperative, long-polling control-plane call better suited to
a script than to TF state. Terraform provisions the IAM/bucket prerequisites;
`build_image.py` builds the image; the runbook wires up the server.

## VPC egress connector (for locked-down accounts)

By default the in-VM host dials back to the server over the **public internet**,
so the server needs a public address with its port reachable. In accounts whose
guardrails strip public `0.0.0.0/0` ingress (e.g. a cloud-custodian policy), that
path can't stay open long enough for the between-turns resume dial-back. Set:

```hcl
module "microvm" {
  source                      = "./terraform"
  enable_vpc_egress_connector = true
  vpc_subnet_ids              = ["subnet-…"]
  vpc_security_group_ids      = ["sg-…"]
}
```

…and the host dials back over your VPC on a **private** address — no public
ingress rule at all.

> **Implementation note.** Lambda MicroVMs network connectors are a new service
> (`lambda-core`); the AWS Terraform provider does not expose a native resource
> for them yet. This module creates the connector-operator IAM role natively and
> creates the connector itself via the AWS CLI in a `null_resource` (so the
> module still needs `aws` CLI available at apply time, with credentials able to
> call `lambda-core create-network-connector`). Swap the `null_resource` for the
> native `aws_lambda_network_connector` resource once the provider ships it.

## Teardown

```bash
terraform destroy
```

Everything is tagged (`project = omnigent-microvm` by default) if you need to
find stragglers. The connector's `destroy` provisioner best-effort deletes it;
ensure no MicroVMs are still using it first.
