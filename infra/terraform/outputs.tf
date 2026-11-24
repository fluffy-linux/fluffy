output "agent_service_account" {
  value = google_service_account.agent.email
}

output "agent_templates" {
  value = { for r, t in google_compute_instance_template.agent : r => t.name }
}

output "scaler_uri" {
  value = google_cloudfunctions2_function.scaler.service_config[0].uri
}
