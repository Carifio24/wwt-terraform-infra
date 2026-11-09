# The WWT image uploader: https://github.com/Carifio24/wwt-image-uploader
#
# Users upload images; workers place them on the sky (WCS/AVM, or plate solving
# with astrometry.net), tile them with toasty, and publish WTML. Pieces:
#
# - A Container Apps environment in its own vnet, logging to its own Log
#   Analytics workspace, holding:
#   - `api`: the FastAPI app (public HTTPS ingress)
#   - `worker-light`, `worker-solve`, `worker-heavy`: Celery workers on the
#     `light`, `solve` and `heavy` queues
#   - `redis`: the Celery broker, as a plain container. Postgres is the source of
#     truth for every image's state, so losing queued messages (e.g. on a
#     restart) only delays work; it doesn't corrupt anything.
#   - a `migrate` job that runs `alembic upgrade head`
# - Postgres (Flexible Server), reachable only from the vnet
# - A storage account with a private `scratch` container (uploads, work files),
#   a public `public` container (previews, tiles, WTML), the frontend's static
#   website, and a file share with the astrometry.net index files
#
# Deployment of the app itself is done by the uploader repo's Azure Pipeline
# (`ci/azure-pipelines.yml`), which builds the images, runs the `migrate` job,
# and points the apps at the new image tag. Terraform only sets the initial
# image, and ignores image changes after that (see `lifecycle` blocks below).
#
# First-time setup order:
#
# 1. Run the uploader pipeline once so that the images exist on Docker Hub (its
#    deploy stage will fail until step 2 is done).
# 2. `terraform apply` this file.
# 3. Upload the index files to the `astrometry-index` share, e.g.:
#    az storage file upload-batch --account-name <prefix>wwtu \
#      --destination astrometry-index --source <dir with index-*.fits>
# 4. Re-run the pipeline: it migrates the database and deploys everything.
#
# Workers run a fixed number of replicas rather than autoscaling on queue
# length: when a queue empties, KEDA scales in by stopping arbitrary replicas,
# including ones in the middle of a long plate solve or tiling job. Scale by
# changing the replica counts below.

locals {
  wwtu_images = {
    app   = "aasworldwidetelescope/wwt-image-uploader-app:latest"
    heavy = "aasworldwidetelescope/wwt-image-uploader-heavy:latest"
  }

  # Container app names are also their hostnames inside the environment.
  wwtu_redis_name = "${var.prefix}-wwtu-redis"

  # Settings shared by the API and all workers (non-secret).
  wwtu_env = {
    "WWTU_REDIS_URL"         = "redis://${local.wwtu_redis_name}:6379/0"
    "WWTU_STORAGE_BACKEND"   = "azure"
    "WWTU_AZURE_ACCOUNT_URL" = azurerm_storage_account.wwtu.primary_blob_endpoint
    "WWTU_PUBLIC_BASE_URL"   = "${azurerm_storage_account.wwtu.primary_blob_endpoint}public"
    "WWTU_CORS_ORIGINS"      = trimsuffix(azurerm_storage_account.wwtu.primary_web_endpoint, "/")
    "AZURE_CLIENT_ID"        = azurerm_user_assigned_identity.wwtu.client_id
    "PYTHONUNBUFFERED"       = "1"
  }
}

resource "azurerm_resource_group" "wwtu" {
  name     = "${var.prefix}-uploader"
  location = var.location
}

# Networking. A separate address space from the Constellations vnet
# (10.0.0.0/16), so that the two could be peered later.

resource "azurerm_virtual_network" "wwtu" {
  name                = "${var.prefix}-wwtu-vnet"
  location            = azurerm_resource_group.wwtu.location
  resource_group_name = azurerm_resource_group.wwtu.name
  address_space       = ["10.20.0.0/16"]
}

resource "azurerm_subnet" "wwtu_apps" {
  name                 = "${var.prefix}-wwtu-apps"
  resource_group_name  = azurerm_resource_group.wwtu.name
  virtual_network_name = azurerm_virtual_network.wwtu.name
  address_prefixes     = ["10.20.0.0/23"]

  delegation {
    name = "containerapps"

    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "wwtu_db" {
  name                 = "${var.prefix}-wwtu-db"
  resource_group_name  = azurerm_resource_group.wwtu.name
  virtual_network_name = azurerm_virtual_network.wwtu.name
  address_prefixes     = ["10.20.2.0/24"]
  # Azure adds this endpoint itself when a Postgres Flexible Server is placed in
  # the subnet; declare it so Terraform doesn't try to remove it.
  service_endpoints = ["Microsoft.Storage"]

  delegation {
    name = "postgres"

    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# Identity used by all the apps: storage access (including signing upload URLs
# with a user delegation key).

resource "azurerm_user_assigned_identity" "wwtu" {
  name                = "${var.prefix}-wwtu"
  location            = azurerm_resource_group.wwtu.location
  resource_group_name = azurerm_resource_group.wwtu.name
}

resource "azurerm_role_assignment" "wwtu_storage" {
  scope                = azurerm_storage_account.wwtu.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.wwtu.principal_id
}

# The service principal behind the Azure DevOps service connection that the
# uploader's pipeline deploys with (`aas@wwtadmindotnetfoundation`; ci/deploy.sh).
# It has no subscription-wide role, so it needs one here to run the migrate job,
# update the apps and upload the frontend
resource "azurerm_role_assignment" "wwtu_pipeline" {
  scope                = azurerm_resource_group.wwtu.id
  role_definition_name = "Contributor"
  principal_id         = "a5d69746-9881-4aae-8679-c4578c0cb83e"
  principal_type       = "ServicePrincipal"
}

# Database

resource "azurerm_private_dns_zone" "wwtu_db" {
  name                = "${var.prefix}-wwtu.private.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.wwtu.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "wwtu_db" {
  name                  = "${var.prefix}-wwtu-db"
  resource_group_name   = azurerm_resource_group.wwtu.name
  private_dns_zone_name = azurerm_private_dns_zone.wwtu_db.name
  virtual_network_id    = azurerm_virtual_network.wwtu.id
}

resource "azurerm_postgresql_flexible_server" "wwtu" {
  name                          = "${var.prefix}-wwtu-db"
  location                      = azurerm_resource_group.wwtu.location
  resource_group_name           = azurerm_resource_group.wwtu.name
  version                       = "16"
  sku_name                      = "B_Standard_B1ms"
  storage_mb                    = 32768
  backup_retention_days         = 14
  delegated_subnet_id           = azurerm_subnet.wwtu_db.id
  private_dns_zone_id           = azurerm_private_dns_zone.wwtu_db.id
  public_network_access_enabled = false
  administrator_login           = "wwtu"
  administrator_password        = var.uploaderDbAdminPassword

  depends_on = [azurerm_private_dns_zone_virtual_network_link.wwtu_db]

  lifecycle {
    # Azure picks a zone if none is given; don't fight it.
    ignore_changes = [zone]
  }
}

resource "azurerm_postgresql_flexible_server_database" "wwtu" {
  name      = "wwtu"
  server_id = azurerm_postgresql_flexible_server.wwtu.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# Storage

resource "azurerm_storage_account" "wwtu" {
  name                     = "${var.prefix}wwtu"
  resource_group_name      = azurerm_resource_group.wwtu.name
  location                 = azurerm_resource_group.wwtu.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"

  # The `public` container serves previews, tiles and WTML to the WWT webclient.
  allow_nested_items_to_be_public = true

  blob_properties {
    # Browsers PUT uploads straight to `scratch` with SAS URLs (which are what
    # actually authorize the write), and the webclient, served from any
    # origin, reads tiles and WTML from `public`.
    cors_rule {
      allowed_origins    = ["*"]
      allowed_methods    = ["GET", "HEAD", "OPTIONS", "PUT"]
      allowed_headers    = ["*"]
      exposed_headers    = ["*"]
      max_age_in_seconds = 3600
    }
  }
}

resource "azurerm_storage_container" "wwtu_scratch" {
  name                  = "scratch"
  storage_account_id    = azurerm_storage_account.wwtu.id
  container_access_type = "private"
}

resource "azurerm_storage_container" "wwtu_public" {
  name                  = "public"
  storage_account_id    = azurerm_storage_account.wwtu.id
  container_access_type = "blob"
}

# Uploads and work files are only needed while an image is being processed.
resource "azurerm_storage_management_policy" "wwtu" {
  storage_account_id = azurerm_storage_account.wwtu.id

  rule {
    name    = "expire-scratch"
    enabled = true

    filters {
      blob_types   = ["blockBlob"]
      prefix_match = ["scratch/"]
    }

    actions {
      base_blob {
        delete_after_days_since_modification_greater_than = 14
      }
    }
  }
}

# The frontend (a static Vite build), uploaded by the pipeline to `$web`.
resource "azurerm_storage_account_static_website" "wwtu" {
  storage_account_id = azurerm_storage_account.wwtu.id
  index_document     = "index.html"
  error_404_document = "index.html"
}

# astrometry.net index files, mounted read-only into the plate-solving workers.
resource "azurerm_storage_share" "wwtu_index" {
  name               = "astrometry-index"
  storage_account_id = azurerm_storage_account.wwtu.id
  quota              = 100 # GiB
}

# Logs. The uploader has its own workspace rather than sharing WWT's default
# one, so that its (sometimes verbose) solver output can't use up the shared
# workspace's daily ingestion cap. It has a cap of its own, too: once 1 GB has
# been ingested in a day, further logs are dropped until the next day.

resource "azurerm_log_analytics_workspace" "wwtu" {
  name                = "${var.prefix}-wwtu-logs"
  location            = azurerm_resource_group.wwtu.location
  resource_group_name = azurerm_resource_group.wwtu.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  daily_quota_gb      = 1
}

# Container Apps

resource "azurerm_container_app_environment" "wwtu" {
  name                       = "${var.prefix}-wwtu"
  location                   = azurerm_resource_group.wwtu.location
  resource_group_name        = azurerm_resource_group.wwtu.name
  log_analytics_workspace_id = azurerm_log_analytics_workspace.wwtu.id
  infrastructure_subnet_id   = azurerm_subnet.wwtu_apps.id

  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }

  lifecycle {
    # Set by Azure for environments with a custom vnet.
    ignore_changes = [infrastructure_resource_group_name]
  }
}

resource "azurerm_container_app_environment_storage" "wwtu_index" {
  name                         = "astrometry-index"
  container_app_environment_id = azurerm_container_app_environment.wwtu.id
  account_name                 = azurerm_storage_account.wwtu.name
  share_name                   = azurerm_storage_share.wwtu_index.name
  access_key                   = azurerm_storage_account.wwtu.primary_access_key
  access_mode                  = "ReadOnly"
}

# Celery broker. Internal TCP ingress only: reachable from the other apps as
# `<name>:6379`, not from outside the environment.
resource "azurerm_container_app" "wwtu_redis" {
  name                         = local.wwtu_redis_name
  container_app_environment_id = azurerm_container_app_environment.wwtu.id
  resource_group_name          = azurerm_resource_group.wwtu.name
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"

  ingress {
    external_enabled = false
    transport        = "tcp"
    target_port      = 6379
    exposed_port     = 6379

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 1
    max_replicas = 1

    container {
      name   = "redis"
      image  = "docker.io/library/redis:7"
      cpu    = 0.25
      memory = "0.5Gi"
    }
  }
}

resource "azurerm_container_app" "wwtu_api" {
  name                         = "${var.prefix}-wwtu-api"
  container_app_environment_id = azurerm_container_app_environment.wwtu.id
  resource_group_name          = azurerm_resource_group.wwtu.name
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.wwtu.id]
  }

  secret {
    name  = "database-url"
    value = local.wwtu_database_url
  }

  secret {
    name  = "api-keys"
    value = var.uploaderApiKeys
  }

  ingress {
    external_enabled = true
    target_port      = 8000

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 1
    max_replicas = 3

    container {
      name   = "api"
      image  = local.wwtu_images.app
      cpu    = 0.5
      memory = "1Gi"
      command = [
        "uvicorn", "wwt_uploader.api.app:app", "--host", "0.0.0.0", "--port", "8000",
        "--workers", "2", "--proxy-headers", "--forwarded-allow-ips", "*",
      ]

      dynamic "env" {
        for_each = local.wwtu_env
        content {
          name  = env.key
          value = env.value
        }
      }

      env {
        name        = "WWTU_DATABASE_URL"
        secret_name = "database-url"
      }

      env {
        name        = "WWTU_API_KEYS"
        secret_name = "api-keys"
      }

      liveness_probe {
        transport = "HTTP"
        port      = 8000
        path      = "/healthz"
      }
    }
  }

  lifecycle {
    ignore_changes = [template[0].container[0].image]
  }
}

locals {
  wwtu_database_url = format(
    "postgresql+psycopg://%s:%s@%s:5432/%s?sslmode=require",
    azurerm_postgresql_flexible_server.wwtu.administrator_login,
    urlencode(var.uploaderDbAdminPassword),
    azurerm_postgresql_flexible_server.wwtu.fqdn,
    azurerm_postgresql_flexible_server_database.wwtu.name,
  )

  # name -> settings for each Celery worker
  wwtu_workers = {
    light = {
      image    = local.wwtu_images.app
      cpu      = 1
      memory   = "2Gi"
      replicas = 1
      command = [
        "celery", "-A", "wwt_uploader.worker.tasks", "worker",
        "-Q", "light", "-n", "light@%h", "-c", "2", "-l", "info",
      ]
      mount_index = false
    }

    # One solve-field process per core.
    solve = {
      image    = local.wwtu_images.heavy
      cpu      = 2
      memory   = "4Gi"
      replicas = 1
      command = [
        "celery", "-A", "wwt_uploader.worker.tasks", "worker",
        "-Q", "solve", "-n", "solve@%h", "-c", "2", "-l", "info",
      ]
      mount_index = true
    }

    # toasty starts its own worker processes, so one job per replica (solo pool).
    # This is the largest Consumption size; if big images need more, add a
    # Dedicated workload profile to the environment and run this worker on it.
    heavy = {
      image    = local.wwtu_images.heavy
      cpu      = 4
      memory   = "8Gi"
      replicas = 1
      command = [
        "celery", "-A", "wwt_uploader.worker.tasks", "worker",
        "-Q", "heavy", "-n", "heavy@%h", "--pool", "solo", "-l", "info",
      ]
      mount_index = false
    }
  }
}

resource "azurerm_container_app" "wwtu_worker" {
  for_each = local.wwtu_workers

  name                         = "${var.prefix}-wwtu-${each.key}"
  container_app_environment_id = azurerm_container_app_environment.wwtu.id
  resource_group_name          = azurerm_resource_group.wwtu.name
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.wwtu.id]
  }

  secret {
    name  = "database-url"
    value = local.wwtu_database_url
  }

  template {
    min_replicas = each.value.replicas
    max_replicas = each.value.replicas

    container {
      name    = "worker"
      image   = each.value.image
      cpu     = each.value.cpu
      memory  = each.value.memory
      command = each.value.command

      dynamic "env" {
        for_each = local.wwtu_env
        content {
          name  = env.key
          value = env.value
        }
      }

      env {
        name        = "WWTU_DATABASE_URL"
        secret_name = "database-url"
      }

      dynamic "volume_mounts" {
        for_each = each.value.mount_index ? [1] : []
        content {
          name = "astrometry-index"
          # The Debian astrometry.net package's default index search path.
          path = "/usr/share/astrometry"
        }
      }
    }

    dynamic "volume" {
      for_each = each.value.mount_index ? [1] : []
      content {
        name         = "astrometry-index"
        storage_name = azurerm_container_app_environment_storage.wwtu_index.name
        storage_type = "AzureFile"
      }
    }
  }

  lifecycle {
    ignore_changes = [template[0].container[0].image]
  }
}

# Database migrations, started by the pipeline before each rollout.
resource "azurerm_container_app_job" "wwtu_migrate" {
  name                         = "${var.prefix}-wwtu-migrate"
  location                     = azurerm_resource_group.wwtu.location
  resource_group_name          = azurerm_resource_group.wwtu.name
  container_app_environment_id = azurerm_container_app_environment.wwtu.id
  workload_profile_name        = "Consumption"
  replica_timeout_in_seconds   = 600
  replica_retry_limit          = 0

  manual_trigger_config {
    parallelism              = 1
    replica_completion_count = 1
  }

  secret {
    name  = "database-url"
    value = local.wwtu_database_url
  }

  template {
    container {
      name    = "migrate"
      image   = local.wwtu_images.app
      cpu     = 0.5
      memory  = "1Gi"
      command = ["alembic", "upgrade", "head"]

      env {
        name        = "WWTU_DATABASE_URL"
        secret_name = "database-url"
      }
    }
  }

  lifecycle {
    ignore_changes = [template[0].container[0].image]
  }
}

output "uploader_api_url" {
  value = "https://${azurerm_container_app.wwtu_api.ingress[0].fqdn}"
}

output "uploader_frontend_url" {
  value = azurerm_storage_account.wwtu.primary_web_endpoint
}
