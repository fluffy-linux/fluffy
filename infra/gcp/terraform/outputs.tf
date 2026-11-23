output "agent_service_account" {
  value = google_service_account.agent.email
}

output "agent_template" {
  value = google_compute_instance_template.agent.name
}

output "scaler_uri" {
  value = google_cloudfunctions2_function.scaler.service_config[0].uri
}
