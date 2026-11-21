variable "location" {
  description = "Azure region for CI."
  type        = string
  default     = "eastus"
}

variable "budget_amount" {
  description = "Monthly budget for the CI resource group, in the subscription's currency.  Pay-as-you-go has no hard cap: this only alerts."
  type        = number
  default     = 50
}

variable "budget_start" {
  description = "First day of the first budget month (RFC 3339, the 1st at midnight UTC)."
  type        = string
  default     = "2026-11-01T00:00:00Z"
}

variable "alert_emails" {
  description = "Who gets the budget alerts.  Set in terraform.tfvars, which is not committed."
  type        = list(string)
}
