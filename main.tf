resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

locals {
  rg_name   = "${var.name_prefix}-rg"
  vnet_cidr = "10.20.0.0/16"
}

resource "azurerm_resource_group" "rg" {
  name     = local.rg_name
  location = var.location
}

# VNET + subnets
resource "azurerm_virtual_network" "vnet" {
  name                = "${var.name_prefix}-vnet"
  address_space       = [local.vnet_cidr]
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_subnet" "sub_app" {
  name                 = "sub-app"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.20.1.0/24"]
}
resource "azurerm_subnet" "sub_vm" {
  name                 = "sub-vm"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.20.2.0/24"]
}
resource "azurerm_subnet" "sub_aks" {
  name                 = "sub-aks"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.20.3.0/24"]
}

# ACR
resource "azurerm_container_registry" "acr" {
  name                = "${var.name_prefix}acr${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  sku                 = "Basic"
  admin_enabled       = true
}

# App Service Plan + Web App
resource "azurerm_service_plan" "asp" {
  name                = "${var.name_prefix}-asp"
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  os_type             = "Linux"
  sku_name            = "B1"
}

resource "azurerm_linux_web_app" "web" {
  name                = "${var.name_prefix}-web-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  service_plan_id     = azurerm_service_plan.asp.id
  site_config {
    application_stack { dotnet_version = "8.0" }
  }
  https_only = true
}

# Public LB + VM Scale Set (2 instances)
resource "azurerm_public_ip" "lb_pip" {
  name                = "${var.name_prefix}-lb-pip"
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  domain_name_label   = lower("${var.name_prefix}-lb")
}

resource "azurerm_lb" "lb" {
  name                = "${var.name_prefix}-lb"
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  sku                 = "Standard"

  frontend_ip_configuration {
    name                 = "fe"
    public_ip_address_id = azurerm_public_ip.lb_pip.id
  }
}

resource "azurerm_lb_backend_address_pool" "bepool" {
  name            = "bepool"
  loadbalancer_id = azurerm_lb.lb.id
}

resource "azurerm_lb_probe" "http" {
  name            = "http-probe"
  loadbalancer_id = azurerm_lb.lb.id
  protocol        = "Tcp"
  port            = 80
}

resource "azurerm_lb_rule" "http" {
  name                           = "http-rule"
  loadbalancer_id                = azurerm_lb.lb.id
  protocol                       = "Tcp"
  frontend_port                  = 80
  backend_port                   = 80
  frontend_ip_configuration_name = "fe"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.bepool.id]
  probe_id                       = azurerm_lb_probe.http.id
}

resource "azurerm_linux_virtual_machine_scale_set" "vmss" {
  name                            = "${var.name_prefix}-vmss"
  resource_group_name             = azurerm_resource_group.rg.name
  location                        = var.location
  sku                             = "Standard_B1s"
  instances                       = 2
  admin_username                  = var.admin_username
  admin_password                  = var.admin_password
  disable_password_authentication = false

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }

  # REQUIRED for VMSS
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  network_interface {
    name    = "nic"
    primary = true

    ip_configuration {
      name      = "ipcfg"
      primary   = true
      subnet_id = azurerm_subnet.sub_vm.id
      load_balancer_backend_address_pool_ids = [
        azurerm_lb_backend_address_pool.bepool.id
      ]
    }
  }

  # Optional SSH key; keep if you use SSH
  admin_ssh_key {
    username   = var.admin_username
    public_key = fileexists("~/.ssh/id_rsa.pub") ? file("~/.ssh/id_rsa.pub") : ""
  }

  upgrade_mode = "Manual"

  # Simple cloud-init to show NGINX behind the LB
  custom_data = base64encode(<<EOF
#cloud-config
packages:
 - nginx
runcmd:
 - systemctl enable nginx
 - systemctl start nginx
EOF
  )
}


# AKS (optional, minimal)
resource "azurerm_kubernetes_cluster" "aks" {
  name                = "${var.name_prefix}-aks"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  dns_prefix          = "${var.name_prefix}-aks"

  default_node_pool {
    name           = "system"
    node_count     = 1
    vm_size        = "Standard_B2s"
    vnet_subnet_id = azurerm_subnet.sub_aks.id
  }
  identity { type = "SystemAssigned" }
  network_profile { network_plugin = "azure" }
}

# FRONT DOOR STANDARD + WAF (routes to Web App + LB)
resource "azurerm_cdn_frontdoor_profile" "afd" {
  name                = "${var.name_prefix}-afd"
  resource_group_name = azurerm_resource_group.rg.name
  sku_name            = "Premium_AzureFrontDoor"
}

resource "azurerm_cdn_frontdoor_endpoint" "afd_ep" {
  name                     = "${var.name_prefix}-ep"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.afd.id
}

resource "azurerm_cdn_frontdoor_origin_group" "og" {
  name                     = "${var.name_prefix}-og"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.afd.id

  # Optional but recommended
  session_affinity_enabled = false

  load_balancing {
    sample_size                        = 4
    successful_samples_required        = 3
    additional_latency_in_milliseconds = 0
  }

  health_probe {
    interval_in_seconds = 30     # REQUIRED
    path                = "/"    # usually your health endpoint
    protocol            = "Http" # REQUIRED: "Http" or "Https"
    request_type        = "GET"  # "GET" or "HEAD"
  }
}

resource "azurerm_cdn_frontdoor_origin" "origin_appsvc" {
  name                           = "appsvc"
  cdn_frontdoor_origin_group_id  = azurerm_cdn_frontdoor_origin_group.og.id
  enabled                        = true
  host_name                      = azurerm_linux_web_app.web.default_hostname
  http_port                      = 80
  https_port                     = 443
  certificate_name_check_enabled = true
  origin_host_header             = azurerm_linux_web_app.web.default_hostname
}

# Front Door origin that points to the LB public FQDN
resource "azurerm_cdn_frontdoor_origin" "origin_lb" {
  name                           = "lb"
  cdn_frontdoor_origin_group_id  = azurerm_cdn_frontdoor_origin_group.og.id
  enabled                        = true

  # Must be an FQDN (not an IP). This exists after you set domain_name_label on the PIP.
  host_name                      = azurerm_public_ip.lb_pip.fqdn
  origin_host_header             = azurerm_public_ip.lb_pip.fqdn

  http_port                      = 80
  # add https_port only if your LB/backend presents a valid cert for that hostname
  # https_port                   = 443

  certificate_name_check_enabled = true

  depends_on = [azurerm_public_ip.lb_pip]  # ensures FQDN is created first
}


resource "azurerm_cdn_frontdoor_route" "route_all" {
  name                          = "route-all"
  cdn_frontdoor_endpoint_id     = azurerm_cdn_frontdoor_endpoint.afd_ep.id
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.og.id

  # 👇 NEW: required by the provider
  cdn_frontdoor_origin_ids = [
    azurerm_cdn_frontdoor_origin.origin_appsvc.id,
    azurerm_cdn_frontdoor_origin.origin_lb.id
  ]

  supported_protocols    = ["Http", "Https"]
  patterns_to_match      = ["/*"]
  https_redirect_enabled = true
  forwarding_protocol    = "MatchRequest"
  link_to_default_domain = true
}


# WAF Policy (this is where your error is)
resource "azurerm_cdn_frontdoor_firewall_policy" "waf" {
  name                = "${var.name_prefix}waf"
  resource_group_name = azurerm_resource_group.rg.name

  sku_name = "Premium_AzureFrontDoor" # <- REQUIRED

  mode = "Prevention"

  managed_rule {
    type    = "DefaultRuleSet"
    version = "1.0"
    action  = "Block" # <- satisfies the “action” requirement
  }
}

# Attach WAF to Front Door (Std/Premium)
resource "azurerm_cdn_frontdoor_security_policy" "sp" {
  name                     = "${var.name_prefix}-sec"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.afd.id

  security_policies {
    firewall {
      cdn_frontdoor_firewall_policy_id = azurerm_cdn_frontdoor_firewall_policy.waf.id
      association {
        patterns_to_match = ["/*"]
        domain {
          cdn_frontdoor_domain_id = azurerm_cdn_frontdoor_endpoint.afd_ep.id
        }

      }
    }
  }

  depends_on = [
    azurerm_cdn_frontdoor_route.route_all,
    azurerm_cdn_frontdoor_origin.origin_appsvc,
    azurerm_cdn_frontdoor_origin.origin_lb
  ]
}