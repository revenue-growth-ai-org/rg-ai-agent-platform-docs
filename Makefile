destroy_auto:
	terraform destroy -var-file="prod.tfvars" -auto-approve
