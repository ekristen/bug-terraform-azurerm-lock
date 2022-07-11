# Example of Terraform AzureRM Lock Bug

This is a repository to reproduce the azurerm lock bug.

[Issue 17565](https://github.com/hashicorp/terraform-provider-azurerm/issues/17565)

## Overview

- This doesn't always trigger the problem.
- Parallelism tends to have an impact on RetryableErrors
  - Reducing to 5 seems to help with this.

## Logs / Evidence

As errors are encountered they are placed into the `logs/` directory.

- [Run 001](logs/001.md)
