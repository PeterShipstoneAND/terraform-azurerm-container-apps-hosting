resource "azurerm_monitor_action_group" "main" {
  count = local.enable_monitoring ? 1 : 0

  name                = "${local.resource_prefix}-actiongroup"
  resource_group_name = local.resource_group.name
  short_name          = local.project_name
  tags                = local.tags

  dynamic "email_receiver" {
    for_each = local.monitor_email_receivers

    content {
      name                    = "Email ${email_receiver.value}"
      email_address           = email_receiver.value
      use_common_alert_schema = true
    }
  }

  dynamic "event_hub_receiver" {
    for_each = local.enable_event_hub ? [0] : []

    content {
      name                    = "Event Hub"
      event_hub_name          = azurerm_eventhub.container_app[0].name
      event_hub_namespace     = azurerm_eventhub_namespace.container_app[0].id
      subscription_id         = data.azurerm_subscription.current.subscription_id
      use_common_alert_schema = true
    }
  }
}

resource "azurerm_application_insights" "main" {
  count = local.enable_monitoring ? 1 : 0

  name                = "${local.resource_prefix}-insights"
  location            = local.resource_group.location
  resource_group_name = local.resource_group.name
  application_type    = "web"
  workspace_id        = azurerm_log_analytics_workspace.container_app.id
  retention_in_days   = 30
  tags                = local.tags
}

resource "azurerm_application_insights_standard_web_test" "main" {
  count = local.enable_monitoring ? 1 : 0

  name                    = "${local.resource_prefix}-http-webcheck"
  resource_group_name     = local.resource_group.name
  location                = local.resource_group.location
  application_insights_id = azurerm_application_insights.main[0].id
  timeout                 = 10
  enabled                 = true

  geo_locations = [
    "emea-se-sto-edge", # UK West
    "emea-nl-ams-azr",  # West Europe
    "emea-ru-msa-edge"  # UK South
  ]

  request {
    url = local.enable_cdn_frontdoor ? "https://${azurerm_cdn_frontdoor_endpoint.endpoint[0].host_name}${local.monitor_endpoint_healthcheck}" : "https://${jsondecode(azapi_resource.default.output).properties.configuration.ingress.fqdn}${local.monitor_endpoint_healthcheck}"
  }

  tags = local.tags
}

resource "azurerm_monitor_metric_alert" "cpu" {
  count = local.enable_monitoring ? 1 : 0

  name                = "${local.resource_prefix}-cpu-alarm"
  resource_group_name = local.resource_group.name
  scopes              = local.enable_worker_container ? [azapi_resource.default.id, azapi_resource.worker[0].id] : [azapi_resource.default.id]
  description         = "Action will be triggered when CPU usage is higher than a defined threshold for longer than 5 minutes"
  window_size         = "PT5M"
  frequency           = "PT5M"
  severity            = 2

  criteria {
    metric_namespace = "microsoft.app/containerapps"
    metric_name      = "UsageNanoCores"
    aggregation      = "Average"
    operator         = "GreaterThan"
    # CPU usage in nanocores (1,000,000,000 nanocores = 1 core)
    threshold = ((local.container_cpu * 10000000) * local.alarm_cpu_threshold_percentage)
  }

  action {
    action_group_id = azurerm_monitor_action_group.main[0].id
  }

  tags = local.tags
}
resource "azurerm_monitor_metric_alert" "memory" {
  count = local.enable_monitoring ? 1 : 0

  name                = "${local.resource_prefix}-memory-alarm"
  resource_group_name = local.resource_group.name
  scopes              = local.enable_worker_container ? [azapi_resource.default.id, azapi_resource.worker[0].id] : [azapi_resource.default.id]
  description         = "Action will be triggered when memory usage is higher than a defined threshold for longer than 5 minutes"
  window_size         = "PT5M"
  frequency           = "PT5M"
  severity            = 2

  criteria {
    metric_namespace = "microsoft.app/containerapps"
    metric_name      = "WorkingSetBytes"
    aggregation      = "Average"
    operator         = "GreaterThan"
    # Memory usage in bytes (1,000,000,000 bytes = 1 GB)
    threshold = ((local.container_memory * 10000000) * local.alarm_memory_threshold_percentage)
  }

  action {
    action_group_id = azurerm_monitor_action_group.main[0].id
  }

  tags = local.tags
}

resource "azurerm_monitor_metric_alert" "http" {
  count = local.enable_monitoring ? 1 : 0

  name                = "${local.resource_prefix}-http-alarm"
  resource_group_name = local.resource_group.name
  # Scope requires web test to come first
  # https://github.com/hashicorp/terraform-provider-azurerm/issues/8551
  scopes      = [azurerm_application_insights_standard_web_test.main[0].id, azurerm_application_insights.main[0].id]
  description = "Action will be triggered when regional availability becomes impacted."
  severity    = 2

  application_insights_web_test_location_availability_criteria {
    web_test_id           = azurerm_application_insights_standard_web_test.main[0].id
    component_id          = azurerm_application_insights.main[0].id
    failed_location_count = 2 # 2 out of 3 locations
  }

  action {
    action_group_id = azurerm_monitor_action_group.main[0].id
  }

  tags = local.tags
}

resource "azurerm_monitor_metric_alert" "count" {
  count = local.enable_monitoring ? 1 : 0

  name                = "${local.resource_prefix}-revision-count"
  resource_group_name = local.resource_group.name
  scopes              = local.enable_worker_container ? [azapi_resource.default.id, azapi_resource.worker[0].id] : [azapi_resource.default.id]
  description         = "Action will be triggered when container count is zero"
  window_size         = "PT5M"
  frequency           = "PT1M"
  severity            = 1

  criteria {
    metric_namespace = "microsoft.app/containerapps"
    metric_name      = "Replicas"
    aggregation      = "Maximum"
    operator         = "LessThan"
    threshold        = 1
  }

  action {
    action_group_id = azurerm_monitor_action_group.main[0].id
  }

  tags = local.tags
}

resource "azurerm_monitor_metric_alert" "redis-load" {
  count = local.enable_redis_cache && local.enable_monitoring ? 1 : 0

  name                = "${local.resource_prefix}-redis-load"
  resource_group_name = local.resource_group.name
  scopes              = [azurerm_redis_cache.default[0].id]
  description         = "Action will be triggered when Redis Server Load is high"
  window_size         = "PT5M"
  frequency           = "PT1M"
  severity            = 2

  criteria {
    metric_namespace = "Microsoft.Cache/Redis"
    metric_name      = "allserverLoad"
    aggregation      = "Average"
    operator         = "GreaterThan"
    # Number used as %
    threshold = 80
  }

  action {
    action_group_id = azurerm_monitor_action_group.main[0].id
  }

  tags = local.tags
}

resource "azurerm_monitor_metric_alert" "latency" {
  count = local.enable_cdn_frontdoor && local.enable_monitoring ? 1 : 0

  name                = "${local.resource_prefix}-latency"
  resource_group_name = local.resource_group.name
  scopes              = [azurerm_cdn_frontdoor_profile.cdn[0].id]
  description         = "Action will be triggered when Front Door latency is higher than 0.5s"
  window_size         = "PT5M"
  frequency           = "PT5M"
  severity            = 2

  criteria {
    metric_namespace = "Microsoft.Cdn/profiles"
    metric_name      = "TotalLatency"
    aggregation      = "Average"
    operator         = "GreaterThan"
    # 1,000ms = 1s
    threshold = 500
  }

  action {
    action_group_id = azurerm_monitor_action_group.main[0].id
  }

  tags = local.tags
}
