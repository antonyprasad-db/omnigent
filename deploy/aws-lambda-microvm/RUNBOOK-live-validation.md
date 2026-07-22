# Live validation runbook — `resume_preserves_host` on real Lambda MicroVMs

Goal: prove the headline claim — `resume_preserves_host = True` — end to end on
real AWS Lambda MicroVMs, not the recording fake. The driver is this PR's
`tests/e2e/integrations/deploy/lambda_microvm/e2e_managed.py`: it forces a real
>900s idle suspend and asserts the **same `host_id`** resumes with workspace
intact.

This runbook is the AWS-side companion to that driver. The IAM templates
(`iam/`), `setup.sh`, and `build_image.py` in this directory provision
everything it needs.

## 0. Prerequisites

```bash
export ACCOUNT_ID=111122223333
export REGION=us-east-1
export ARTIFACT_BUCKET=omnigent-microvm-artifacts-$ACCOUNT_ID

./setup.sh          # IAM roles + bucket + upload build context
python build_image.py   # build the image WITH hooks enabled (needs boto3>=1.43)
```

`build_image.py` prints the `image_identifier` ARN on success — put it in the
server config below.

## 1. Stand up a reachable Omnigent server

The in-VM host dials **out** to `server_url` (`OMNIGENT_SERVER`); the server
never reaches into the VM. So the server needs to be reachable at `server_url`
from wherever the VM's egress lands. Two topologies:

- **Public egress (default).** VM egress goes to the public internet, so the
  server needs a public address and its port open to the VM's (non-fixed)
  source IP. Simple, but see the security-guardrail note below.
- **VPC egress connector (recommended for locked-down accounts).** Attach an
  egress network connector via `sandbox.lambda_microvm.egress_network_connectors`
  (or `OMNIGENT_LAMBDA_MICROVM_EGRESS_CONNECTORS`). The host then dials back over
  your VPC and the server can sit on a **private** address — no public ingress
  rule at all.

Server config (`config.yaml`):

```yaml
sandbox:
  provider: lambda_microvm
  server_url: http://<SERVER_HOST>:6767    # public DNS, or private DNS if using a connector
  lambda_microvm:
    region: us-east-1
    image_identifier: arn:aws:lambda:us-east-1:<ACCOUNT_ID>:microvm-image:omnigent-host
    execution_role_arn: arn:aws:iam::<ACCOUNT_ID>:role/omnigent-microvm-exec
    # env: names of SERVER-process env vars to inject into the VM (values, not names, stay in the server env)
    env: [CLAUDE_CODE_USE_BEDROCK, AWS_REGION, ANTHROPIC_MODEL]
    # egress_network_connectors: [arn:aws:...:network-connector:...]   # for the VPC-egress topology
```

Run it (single-user, no web UI build required):

```bash
OMNIGENT_LOCAL_SINGLE_USER=1 OMNIGENT_SKIP_WEB_UI=true \
CLAUDE_CODE_USE_BEDROCK=1 AWS_REGION=us-east-1 \
ANTHROPIC_MODEL=us.anthropic.claude-sonnet-4-20250514-v1:0 \
  omnigent server --host 0.0.0.0 --port 6767 --config config.yaml --agent <agent-path>
```

Notes learned the hard way:
- `OMNIGENT_LOCAL_SINGLE_USER=1` is what opens `/v1/agents` and `/v1/sessions`
  for the driver. Without it the server is fail-closed header-auth and the
  driver gets 401. (`OMNIGENT_AUTH_ENABLED` is the multi-user opt-in — not this.)
- Key-free model path: the **LLM turn runs inside the VM**, which assumes the
  exec role (it has `bedrock:InvokeModel`), so the **server** role does not need
  Bedrock. The claude-sdk harness talks to Bedrock via `CLAUDE_CODE_USE_BEDROCK=1`.
- `OMNIGENT_SKIP_WEB_UI=true` avoids the npm/web-UI build on install.

## 2. Sanity check

```bash
curl -s http://<SERVER_HOST>:6767/v1/info | jq '{managed_sandboxes_enabled, sandbox_provider}'
# expect: managed_sandboxes_enabled=true, sandbox_provider="lambda_microvm"
```

## 3. Run the validation

```bash
python tests/e2e/integrations/deploy/lambda_microvm/e2e_managed.py \
  --server http://<SERVER_HOST>:6767 \
  --idle-wait 960 \     # > the 900s idle timer → forces a REAL suspend→resume
  --timeout 420         # cold boot + image pull + resume are slow; be generous
```

Expected: host registers, first turn returns the first sentinel, then after the
960s sleep the follow-up turn is served by the **same `host_id`** → `PASS`.
Capture full stdout (mask IDs) as the evidence artifact.

## Findings that shaped this runbook

1. **Image hooks must be ENABLED (`build_image.py`).** The README's
   `create-microvm-image` snippet omits `--hooks`, so the image builds fine but
   the first `RunMicrovm` fails: `ValidationException: The run hook must be
   enabled in the MicroVM image to pass the run hook payload`. run / resume /
   suspend / terminate + the ready image-hook must all be ENABLED.

2. **IAM action namespace is `lambda:`, not `lambda-microvms:`** (see `iam/`).
   The boto3 *service* is `lambda-microvms`, but every IAM action is
   `lambda:CreateMicrovmImage`, `lambda:RunMicrovm`, `lambda:SuspendMicrovm`,
   etc. The build path also needs `lambda:PassNetworkConnector` on the
   `INTERNET_EGRESS` connector (to pull the host image) plus `iam:PassRole` on
   the build + exec roles. A `PassedToService=lambda.amazonaws.com` condition on
   `iam:PassRole` failed closed at build time — scope by resource instead.

3. **`lambda-microvms` is newer than awscli v2.34.x.** The CLI doesn't know the
   service yet; use **boto3 >= 1.43** for the image-build / run calls (hence
   `build_image.py` instead of an `aws lambda-microvms ...` one-liner).

4. **Cold-boot vs. the server's 120s host-online budget.** The first cold boot
   pulls the ~1 GB `omnigent-host` image and does a nested container build
   *before* the host process starts and dials back, which can exceed
   `MANAGED_HOST_ONLINE_TIMEOUT_S = 120` (`server/managed_hosts.py`). The
   constant isn't operator-overridable today; on a slow first boot the launch
   times out even though the VM later comes up healthy. Consider making it
   env-tunable (e.g. `OMNIGENT_MANAGED_HOST_ONLINE_TIMEOUT_S`) so cold-pull
   accounts don't have to patch source.

5. **Public-ingress security guardrails.** In accounts with an
   auto-remediation control that strips `0.0.0.0/0` ingress rules (e.g. a
   cloud-custodian policy), the public-egress topology can't keep the server
   port open long enough for the between-turns resume dial-back. Use the VPC
   egress connector topology there.
