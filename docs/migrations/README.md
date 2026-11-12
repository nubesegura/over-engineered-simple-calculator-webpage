# Migrations

`003-move-api-edge-out/removed.tf.example` is a model of the Terraform `removed` blocks that this repository used when the API certificate, the SSM parameter with its ARN, the weighted Route 53 records, the weights guard and the certificate expiry alarms (with their SNS topic) moved to the repository `over-engineered-simple-calculator-shared-resources`. It is an example kept for reference, not part of any module, so it is never applied by the pipeline.

The pattern: the new owner first imports the existing resources into its own state; only then does the old owner add a `removed` block per resource with `lifecycle { destroy = false }`. Terraform forgets the resource in the old state and deletes nothing in AWS, so there is no downtime and no re-creation.

Warning: never apply `removed` blocks before the new owner has adopted the resources in the same environment. Until then the old state is the only one that knows them, and a mistake (for example a block without `destroy = false`, or removing the resource definition without a block) would delete live certificates, records or alarms.
