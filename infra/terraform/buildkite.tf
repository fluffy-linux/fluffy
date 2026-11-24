# Buildkite: the cluster, its two self-hosted queues and the two
# pipelines.  Imported 2026-11-24 from what had been set up by hand.  The
# agent token isn't managed here (Terraform would keep its value in state);
# it stays in Secret Manager, made by hand.  The cluster's hosted queues
# (linux-*, macos-*, windows-*), which came with the account, are left
# alone.

resource "buildkite_cluster" "default" {
  name                           = "Default cluster"
  hosted_container_cache_enabled = true
  hosted_git_mirror_enabled      = false
}

# The default queue: CI's steps name none, so they run here, on the GCP
# agents the scaler starts (agents.tf, scaler.tf).
resource "buildkite_cluster_queue" "mufasa" {
  cluster_id           = buildkite_cluster.default.id
  key                  = var.buildkite_queue
  description          = ""
  retry_agent_affinity = "prefer-warmest"
  use_github_app_token = true
}

# The mirror agent's queue (mirror/; its GCP agent is still to come).
resource "buildkite_cluster_queue" "mirror" {
  cluster_id           = buildkite_cluster.default.id
  key                  = "mirror"
  description          = ""
  retry_agent_affinity = "prefer-warmest"
  use_github_app_token = false
}

# CI: every push to 🐶 (and pull requests) runs the plan step, which
# uploads the world's steps (.buildkite/pipeline.yml).
resource "buildkite_pipeline" "fluffy" {
  name                 = "fluffy"
  slug                 = "fluffy"
  description          = "Fluffy Linux"
  repository           = "https://github.com/fluffy-linux/fluffy.git"
  cluster_id           = buildkite_cluster.default.id
  default_branch       = "🐶"
  branch_configuration = "🐶"
  visibility           = "PUBLIC"
  allow_rebuilds       = true
  steps = chomp(<<-EOT
    steps:
      - label: ":pipeline:"
        command: "buildkite-agent pipeline upload"
  EOT
  )
  provider_settings = {
    build_branches                                      = true
    build_check_run_completed                           = false
    build_create_event                                  = false
    build_deployment_status_created                     = false
    build_issue_comment_created                         = false
    build_issues                                        = false
    build_merge_group_checks_requested                  = false
    build_pull_request_base_branch_changed              = false
    build_pull_request_converted_to_draft               = false
    build_pull_request_dequeued                         = false
    build_pull_request_edited                           = false
    build_pull_request_forks                            = false
    build_pull_request_labels_changed                   = false
    build_pull_request_merge_commits                    = false
    build_pull_request_ready_for_review                 = false
    build_pull_request_reopened                         = false
    build_pull_request_review_comment_created           = false
    build_pull_request_review_dismissed                 = false
    build_pull_request_review_requested                 = false
    build_pull_request_review_submitted                 = false
    build_pull_request_stacks                           = false
    build_pull_requests                                 = true
    build_release_created                               = false
    build_release_published                             = false
    build_release_released                              = false
    build_tags                                          = false
    cancel_deleted_branch_builds                        = false
    cancel_when_merge_group_destroyed                   = false
    filter_enabled                                      = false
    github_workflow_access_tokens_enabled               = false
    ignore_default_branch_pull_requests                 = false
    issue_comment_command_word                          = "/bk"
    issue_comment_match_mode                            = "exact"
    prefix_pull_request_fork_branch_names               = true
    prevent_custom_statuses_from_using_buildkite_prefix = true
    publish_blocked_as_pending                          = false
    publish_commit_status                               = true
    publish_commit_status_per_step                      = false
    pull_request_branch_filter_enabled                  = false
    review_comment_command_word                         = "/bk"
    review_comment_match_mode                           = "exact"
    separate_pull_request_statuses                      = false
    skip_builds_for_closed_pull_requests                = true
    skip_builds_for_existing_commits                    = false
    skip_pull_request_builds_for_existing_commits       = true
    trigger_mode                                        = "code"
    use_merge_group_base_commit_for_git_diff_base       = false
    use_step_key_as_commit_status                       = false
  }
}

# The nightly fork sync (mirror/pipeline.yml): only on its schedule, never
# on a push.
resource "buildkite_pipeline" "mirror" {
  name           = "mirror"
  slug           = "mirror"
  description    = "Mirror Fluffy Linux dependencies"
  repository     = "https://github.com/fluffy-linux/fluffy.git"
  cluster_id     = buildkite_cluster.default.id
  default_branch = "🐶"
  visibility     = "PRIVATE"
  allow_rebuilds = true
  steps = chomp(<<-EOT
    steps:
      - label: ":pipeline: mirror"
        command: "buildkite-agent pipeline upload mirror/pipeline.yml"
        agents:
          queue: "mirror"
  EOT
  )
  provider_settings = {
    build_branches                                      = true
    build_check_run_completed                           = false
    build_create_event                                  = false
    build_deployment_status_created                     = false
    build_issue_comment_created                         = false
    build_issues                                        = false
    build_merge_group_checks_requested                  = false
    build_pull_request_base_branch_changed              = false
    build_pull_request_converted_to_draft               = false
    build_pull_request_dequeued                         = false
    build_pull_request_edited                           = false
    build_pull_request_forks                            = false
    build_pull_request_labels_changed                   = false
    build_pull_request_merge_commits                    = false
    build_pull_request_ready_for_review                 = false
    build_pull_request_reopened                         = false
    build_pull_request_review_comment_created           = false
    build_pull_request_review_dismissed                 = false
    build_pull_request_review_requested                 = false
    build_pull_request_review_submitted                 = false
    build_pull_request_stacks                           = false
    build_pull_requests                                 = true
    build_release_created                               = false
    build_release_published                             = false
    build_release_released                              = false
    build_tags                                          = false
    cancel_deleted_branch_builds                        = false
    cancel_when_merge_group_destroyed                   = false
    filter_enabled                                      = false
    github_workflow_access_tokens_enabled               = false
    ignore_default_branch_pull_requests                 = false
    issue_comment_command_word                          = "/bk"
    issue_comment_match_mode                            = "exact"
    prefix_pull_request_fork_branch_names               = true
    prevent_custom_statuses_from_using_buildkite_prefix = true
    publish_blocked_as_pending                          = false
    publish_commit_status                               = true
    publish_commit_status_per_step                      = false
    pull_request_branch_filter_enabled                  = false
    review_comment_command_word                         = "/bk"
    review_comment_match_mode                           = "exact"
    separate_pull_request_statuses                      = false
    skip_builds_for_closed_pull_requests                = true
    skip_builds_for_existing_commits                    = false
    skip_pull_request_builds_for_existing_commits       = true
    trigger_mode                                        = "none"
    use_merge_group_base_commit_for_git_diff_base       = false
    use_step_key_as_commit_status                       = false
  }
}

resource "buildkite_pipeline_schedule" "mirror_daily" {
  pipeline_id = buildkite_pipeline.mirror.id
  label       = "Daily"
  cronline    = "@daily"
  branch      = "🐶"
  commit      = "HEAD"
  enabled     = true
}
