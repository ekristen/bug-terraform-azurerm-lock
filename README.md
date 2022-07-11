# Example of Terraform AzureRM Lock Bug

This is a repository to reproduce the azurerm lock bug.

[Issue 17565](https://github.com/hashicorp/terraform-provider-azurerm/issues/17565)

## Overview

- This doesn't always trigger the problem.
- Parallelism tends to have an impact on RetryableErrors
  - Reducing to 5 seems to help with this.

## Usage

There's a nice helper script that just loops through plans/apply/destroy, as soon as an error is encountered it exits.

**Note:** this assumes you have all the appropriate environment variables set for authenticating to Azure.

```console
bash run.sh
```

### Authenticating

The script and the entire project for reproducing uses a service principal.

```bash
export ARM_TENANT_ID="<tenant-id>"
export ARM_CLIENT_ID="<client-id>"
export ARM_CLIENT_SECRET="<client-secret>"
export ARM_SUBSCRIPTION_ID="<subscription-id>"
```

## Logs / Evidence

As errors are encountered they are placed into the `logs/` directory.

### Runs

**Note:** distinct runs for errors.

- [Run 001](logs/001.md)

### Errors

- `Error: waiting for completion of Security Group Association for Network Interface: (Name "test-tpl-terraform-azure-j0xyh-private-server" / Resource Group "test-tpl-terraform-azure-j0xyh"): Code="InternalServerError" Message="An error occurred." Details=[]`
- `Error: waiting for update of Network Interface: (Name "tf-azure-lock-bug-wmoql-private" / Resource Group "tf-azure-lock-bug-wmoql"): Code="OperationNotAllowed" Message="Operation 'startTenantUpdate' is not allowed on VM 'tf-azure-lock-bug-wmoql-private' since the VM is marked for deletion. You can only retry the Delete operation (or wait for an ongoing one to complete)." Details=[]`
