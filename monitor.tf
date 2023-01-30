resource "azurerm_monitor_action_group" "main" {
  count = local.enable_monitoring ? 1 : 0

  name                = "${local.resource_prefix}-actiongroup"
  resource_group_name = local.resource_group.name
  short_name          = "${local.project_name}-monitor"
  tags                = local.tags

  dynamic "email_receiver" {
    for_each = local.monitor_email_receivers != [] ? local.monitor_email_receivers : []

    content {
      name                    = "Email ${email_receiver.value}"
      email_address           = email_receiver.value
      use_common_alert_schema = true
    }
  }

  # todo: add support for multiple webhook endpoints
  # webhook_receiver = local.monitor_webook_receiver ? {
  #   name                    = "Webhook"
  #   use_common_alert_schema = true
  # } : {}

  dynamic "event_hub_receiver" {
    for_each = local.enable_event_hub ? [0] : null

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

  name                = "${local.resource_prefix}-container-insights"
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
  name                = "${local.resource_prefix}-cpu-alarm"
  resource_group_name = local.resource_group.name
  scopes              = local.enable_worker_container ? [azapi_resource.default.id, azapi_resource.worker[0].id] : [azapi_resource.default.id]
  description         = "Action will be triggered when CPU usage is higher than usual"
  window_size         = "PT5M"
  frequency           = "PT5M"

  dynamic_criteria {
    metric_namespace  = "microsoft.app/containerapps"
    metric_name       = "UsageNanoCores"
    aggregation       = "Total"
    operator          = "GreaterThan"
    alert_sensitivity = "Medium"
  }

  action {
    action_group_id = azurerm_monitor_action_group.main[0].id
  }

  tags = local.tags
}

resource "azurerm_monitor_metric_alert" "http" {
  name                = "${local.resource_prefix}-http-alarm"
  resource_group_name = local.resource_group.name
  # Scope requires web test to come first
  # https://github.com/hashicorp/terraform-provider-azurerm/issues/8551
  scopes      = [azurerm_application_insights_standard_web_test.main[0].id, azurerm_application_insights.main[0].id]
  description = "Action will be triggered when regional availability becomes impacted."

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
