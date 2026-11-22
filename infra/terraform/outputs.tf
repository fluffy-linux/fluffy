output "resource_group" {
  value = azurerm_resource_group.ci.name
}

output "agent_identity_client_id" {
  description = "Client ID of the agents' managed identity (for IMDS token requests)."
  value       = azurerm_user_assigned_identity.agent.client_id
}

output "key_vault_name" {
  value = azurerm_key_vault.ci.name
}

output "gallery_name" {
  value = azurerm_shared_image_gallery.ci.name
}

output "agent_image_definition" {
  value = azurerm_shared_image.agent_nvme.name
}

output "agents_subnet_id" {
  value = azurerm_subnet.agents.id
}
