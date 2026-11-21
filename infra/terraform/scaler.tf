# The scaler: a timer-triggered function (infra/scaler) that raises each
# agent scale set's size to meet its Buildkite queue, every minute.  Flex
# Consumption, within its free grant at this volume.  terraform apply also
# deploys its code, whenever the code changes (scaler_code below).

resource "azurerm_user_assigned_identity" "scaler" {
  name                = "fluffy-ci-scaler"
  resource_group_name = azurerm_resource_group.ci.name
  location            = azurerm_resource_group.ci.location
}

# The function's own storage: its deployment package and the host's
# bookkeeping (the timer's lock).  No account keys: the function reaches
# it as its managed identity.
resource "azurerm_storage_account" "scaler" {
  name                            = "fluffyscaler${random_string.suffix.result}"
  resource_group_name             = azurerm_resource_group.ci.name
  location                        = azurerm_resource_group.ci.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false
}

resource "azurerm_storage_container" "scaler" {
  name                  = "deployment"
  storage_account_id    = azurerm_storage_account.scaler.id
  container_access_type = "private"
}

resource "azurerm_role_assignment" "scaler_storage" {
  scope                = azurerm_storage_account.scaler.id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = azurerm_user_assigned_identity.scaler.principal_id
}

resource "azurerm_role_assignment" "scaler_deploy" {
  scope                = azurerm_storage_account.scaler.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

# The agent token, for Buildkite's agent metrics API.
resource "azurerm_role_assignment" "scaler_vault" {
  scope                = azurerm_key_vault.ci.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.scaler.principal_id
}

# Reading and resizing the agent scale sets, and nothing else.
resource "azurerm_role_assignment" "scaler_scale_sets" {
  for_each             = azurerm_orchestrated_virtual_machine_scale_set.agents
  scope                = each.value.id
  role_definition_name = "Virtual Machine Contributor"
  principal_id         = azurerm_user_assigned_identity.scaler.principal_id
}

resource "azurerm_service_plan" "scaler" {
  name                = "fluffy-ci-scaler"
  resource_group_name = azurerm_resource_group.ci.name
  location            = azurerm_resource_group.ci.location
  os_type             = "Linux"
  sku_name            = "FC1"
}

resource "azurerm_function_app_flex_consumption" "scaler" {
  name                = "fluffy-ci-scaler-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.ci.name
  location            = azurerm_resource_group.ci.location
  service_plan_id     = azurerm_service_plan.scaler.id

  storage_container_type            = "blobContainer"
  storage_container_endpoint        = "${azurerm_storage_account.scaler.primary_blob_endpoint}${azurerm_storage_container.scaler.name}"
  storage_authentication_type       = "UserAssignedIdentity"
  storage_user_assigned_identity_id = azurerm_user_assigned_identity.scaler.id

  runtime_name           = "python"
  runtime_version        = "3.12"
  instance_memory_in_mb  = 512
  maximum_instance_count = 40

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.scaler.id]
  }

  site_config {}

  app_settings = {
    # The host's storage, as the managed identity.  The provider would set
    # AzureWebJobsStorage to a connection string with an empty account key,
    # which takes precedence over the __ settings; empty, it doesn't.
    AzureWebJobsStorage              = ""
    AzureWebJobsStorage__accountName = azurerm_storage_account.scaler.name
    AzureWebJobsStorage__credential  = "managedidentity"
    AzureWebJobsStorage__clientId    = azurerm_user_assigned_identity.scaler.client_id

    SCALER_IDENTITY_CLIENT_ID = azurerm_user_assigned_identity.scaler.client_id
    KEY_VAULT                 = azurerm_key_vault.ci.name
    SUBSCRIPTION_ID           = data.azurerm_client_config.current.subscription_id
    RESOURCE_GROUP            = azurerm_resource_group.ci.name
    SCALE_SETS = jsonencode({
      for k, q in var.agent_queues : q.buildkite_queue => {
        vmss = azurerm_orchestrated_virtual_machine_scale_set.agents[k].name
        max  = q.max_instances
      } if q.buildkite_queue != null
    })
  }

  depends_on = [
    azurerm_role_assignment.scaler_storage,
    azurerm_role_assignment.scaler_vault,
    azurerm_role_assignment.scaler_scale_sets,
  ]
}

# The scaler's code, zipped by Terraform and deployed with the Azure CLI
# (az login's session), again whenever its checksum changes.  Azure builds
# it remotely: pip installs requirements.txt for the runtime's Python.
data "archive_file" "scaler" {
  type        = "zip"
  source_dir  = "${path.module}/../scaler"
  output_path = "${path.module}/.terraform/scaler.zip"
  excludes    = ["__pycache__", "__pycache__/*"]
}

resource "terraform_data" "scaler_code" {
  triggers_replace = [
    data.archive_file.scaler.output_base64sha256,
    azurerm_function_app_flex_consumption.scaler.id,
  ]

  provisioner "local-exec" {
    command = <<-EOT
      az functionapp deployment source config-zip \
          --resource-group "${azurerm_resource_group.ci.name}" \
          --name "${azurerm_function_app_flex_consumption.scaler.name}" \
          --src "${data.archive_file.scaler.output_path}" \
          --build-remote true
    EOT
  }
}

output "scaler_function_app" {
  value = azurerm_function_app_flex_consumption.scaler.name
}
