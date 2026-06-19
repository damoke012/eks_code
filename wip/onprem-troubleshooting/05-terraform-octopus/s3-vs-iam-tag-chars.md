# S3 Tag Value Char Restrictions (vs IAM Tags)

**Symptom:**
- Terraform apply succeeds for IAM resources but fails on `aws_s3_bucket_tagging` with:
  ```
  Error: error tagging S3 Bucket ... : InvalidTag: ...
  ```
- Tag value contains parentheses or other "unusual" characters that IAM accepted

**Root cause:**
S3's `PutBucketTagging` validation is STRICTER than IAM tag validation:
- IAM tag value: allows almost any printable ASCII including `(` `)` `,` `:` etc.
- S3 tag value: rejects `(` `)` and a few other chars

Both technically follow [AWS general tag rules](https://docs.aws.amazon.com/general/latest/gr/aws_tagging.html#tag-conventions) but S3 has a tighter validator.

Real example: a cost-allocation tag with value `Cloud Platform (On-Prem)` worked on IAM resources, failed on S3 buckets in the same apply.

**IaC coverage:** ✓ (codified as a tagging convention — use `-` separator)

**IaC location:**
- `iaac-talos/deploy/terraform/<module>/main.tf` — tag values use `-` separator
- Variant: tag schema in module's `variables.tf`

### Resolution via IaC

Replace `()` with `-` in tag values. Update tagging schema in modules.

### Manual resolution

```bash
# Identify the problematic tags
cd ~/work/iaac-talos
grep -rn "tags = {" deploy/terraform/ | grep "("

# Fix each — replace () with -
# OLD: Owner = "Cloud Platform (On-Prem)"
# NEW: Owner = "Cloud Platform - On-Prem"

# Re-run plan
cd deploy/terraform
terraform plan
# Expect: clean plan, no InvalidTag error
```

### Verification

```bash
# After apply, verify tags landed
aws --profile usx-dev s3api get-bucket-tagging --bucket <bucket-name>
# Expect: JSON with tags listed
```

### Prevention

- **Tag standard**: enforce `-` (not `()`, no `,`, no `:` in values)
- **Pre-commit hook** (planned): grep for `tags = {.*[\(\)].*}` in TF files, reject
- **Module convention**: encode tag schema in module-level `variables.tf` with validation

### Related

- [[octopus-tfapply-variable]] — affects how this surfaces
- Memory: `[S3 tag values reject parentheses]`

### Memory pointers

- `[feedback_s3_vs_iam_tag_chars]` — codified gotcha
