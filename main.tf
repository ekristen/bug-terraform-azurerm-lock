##########################################################################################
# VARIABLES
##########################################################################################
variable "location" {
  description = "The Azure Location to use for Resource Group"
  default     = "eastus"
  type        = string
}

##########################################################################################
# PROVIDERS
##########################################################################################
provider "azurerm" {
  use_oidc = true
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

##########################################################################################
# LOCAL VARIABLES
##########################################################################################
locals {
  default_environment = "tf-azure-lock-bug"
  default_stage       = random_string.uid.result

  cidr = "10.130.8.0/21"

  cidr_block        = local.cidr
  edge_cidr_block   = cidrsubnet(local.cidr_block, 3, 0) // Given /16, x.y.100.0/24
  server_cidr_block = cidrsubnet(local.cidr_block, 3, 1) // Given /16, x.y.100.0/24

  bastion_private_ip = cidrhost(local.edge_cidr_block, 25)
  private_private_ip = cidrhost(local.server_cidr_block, 25)
}

##########################################################################################
# DATA Sources
##########################################################################################
data "azurerm_client_config" "current" {}

##########################################################################################
# GLOBAL Resources
##########################################################################################
resource "random_string" "uid" {
  length  = 5
  special = false
  lower   = true
  upper   = false
  numeric = true
}

module "label" {
  source      = "git::https://github.com/cloudposse/terraform-null-label.git?ref=0.25.0"
  context     = module.this.context
  environment = module.this.context.environment != null ? null : local.default_environment
  stage       = module.this.context.stage != null ? null : local.default_stage
}

##########################################################################################
# Resources - Resource Group
##########################################################################################

resource "azurerm_resource_group" "default" {
  name     = module.label.id
  location = var.location
  tags     = module.label.tags
  provider = azurerm
}


##########################################################################################
# SSH
##########################################################################################

locals {
  private_key_filename = "./secrets/${module.label.id}.key"
}

resource "tls_private_key" "default" {
  algorithm = "RSA"
}

resource "azurerm_ssh_public_key" "default" {
  name                = module.label.id
  resource_group_name = azurerm_resource_group.default.name
  location            = azurerm_resource_group.default.location
  public_key          = tls_private_key.default.public_key_openssh
  tags                = module.label.tags
}

resource "local_sensitive_file" "default" {
  depends_on      = [tls_private_key.default]
  content         = tls_private_key.default.private_key_pem
  filename        = local.private_key_filename
  file_permission = "0600"
}


##########################################################################################
# Network
##########################################################################################

resource "azurerm_virtual_network" "default" {
  name                = module.label.id
  location            = azurerm_resource_group.default.location
  resource_group_name = azurerm_resource_group.default.name
  address_space       = [local.cidr]
  tags                = module.label.tags
}

resource "azurerm_nat_gateway" "default" {
  name                    = module.label.id
  location                = azurerm_resource_group.default.location
  resource_group_name     = azurerm_resource_group.default.name
  sku_name                = "Standard"
  idle_timeout_in_minutes = 4
  tags                    = module.label.tags
}

resource "azurerm_public_ip" "default" {
  name                = module.label.id
  location            = azurerm_resource_group.default.location
  resource_group_name = azurerm_resource_group.default.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = module.label.tags
}

resource "azurerm_nat_gateway_public_ip_association" "default" {
  nat_gateway_id       = azurerm_nat_gateway.default.id
  public_ip_address_id = azurerm_public_ip.default.id
}

##########################################################################################
# Edge Subnets
##########################################################################################
module "edge_subnet_label" {
  source     = "git::https://github.com/cloudposse/terraform-null-label.git?ref=0.25.0"
  attributes = ["edge"]
  context    = module.label.context
}

resource "azurerm_subnet" "edge" {
  name                 = module.edge_subnet_label.id
  resource_group_name  = azurerm_resource_group.default.name
  virtual_network_name = azurerm_virtual_network.default.name
  address_prefixes     = [local.edge_cidr_block]
}

resource "azurerm_route_table" "edge" {
  name                = module.edge_subnet_label.id
  location            = azurerm_resource_group.default.location
  resource_group_name = azurerm_resource_group.default.name
  tags                = module.edge_subnet_label.tags
}

resource "azurerm_subnet_route_table_association" "edge" {
  subnet_id      = azurerm_subnet.edge.id
  route_table_id = azurerm_route_table.edge.id
}

##########################################################################################
# Server Subnets
##########################################################################################
module "server_subnet_label" {
  source     = "git::https://github.com/cloudposse/terraform-null-label.git?ref=0.25.0"
  attributes = ["server"]
  context    = module.label.context
}

resource "azurerm_subnet" "server" {
  name                 = module.server_subnet_label.id
  resource_group_name  = azurerm_resource_group.default.name
  virtual_network_name = azurerm_virtual_network.default.name
  address_prefixes     = [local.server_cidr_block]
}

resource "azurerm_route_table" "server" {
  name                = module.server_subnet_label.id
  location            = azurerm_resource_group.default.location
  resource_group_name = azurerm_resource_group.default.name
  tags                = module.server_subnet_label.tags
}

resource "azurerm_subnet_route_table_association" "server" {
  subnet_id      = azurerm_subnet.server.id
  route_table_id = azurerm_route_table.server.id
}

##########################################################################################
# Bastion
##########################################################################################
module "bastion_label" {
  source     = "git::https://github.com/cloudposse/terraform-null-label.git?ref=0.25.0"
  attributes = ["bastion"]
  context    = module.label.context
}

locals {
  bastion_ingress_rules = [
    {
      priority                   = 100
      access                     = "Allow"
      protocol                   = "*"
      source_port_range          = "*"
      destination_port_range     = "22"
      source_address_prefix      = "0.0.0.0/0"
      destination_address_prefix = "0.0.0.0/0"
    }
  ]
  bastion_egress_rules = [
    {
      priority                   = 100
      access                     = "Allow"
      protocol                   = "*"
      source_port_range          = "*"
      destination_port_range     = "*"
      source_address_prefix      = "0.0.0.0/0"
      destination_address_prefix = "0.0.0.0/0"
    }
  ]

  bastion_default_ip_configuration = {
    name                          = module.bastion_label.id
    subnet_id                     = azurerm_subnet.edge.id
    private_ip_address_allocation = "Static"
    private_ip_address            = local.bastion_private_ip
    public_ip_address_id          = azurerm_public_ip.bastion.id
    primary                       = true
  }

  resolved_bastion_ip_configuration = merge({}, { default = local.bastion_default_ip_configuration })

  resolved_bastion_ingress_security_group_rules = [for r in local.bastion_ingress_rules : {
    name                       = lower("inbound-${r.priority}-${r.access}-${r.protocol}-${r.source_port_range}-${r.destination_port_range}")
    description                = "${r.access} Inbound for ${r.protocol}"
    priority                   = r.priority
    direction                  = "Inbound"
    access                     = r.access
    protocol                   = r.protocol
    source_port_range          = r.source_port_range
    destination_port_range     = r.destination_port_range
    source_address_prefix      = r.source_address_prefix
    destination_address_prefix = r.destination_address_prefix
  }]

  resolved_bastion_egress_security_group_rules = [for r in local.bastion_egress_rules : {
    name                       = lower("outbound-${r.priority}-${r.access}-${r.protocol}-${r.source_port_range}-${r.destination_port_range}")
    description                = "${r.access} Outbound for ${r.protocol}"
    priority                   = r.priority
    direction                  = "Outbound"
    access                     = r.access
    protocol                   = r.protocol
    source_port_range          = r.source_port_range
    destination_port_range     = r.destination_port_range
    source_address_prefix      = r.source_address_prefix
    destination_address_prefix = r.destination_address_prefix
  }]

  bastion_security_group_rules = concat(local.resolved_bastion_ingress_security_group_rules, local.resolved_bastion_egress_security_group_rules)
}

resource "azurerm_public_ip" "bastion" {
  name                = module.bastion_label.id
  resource_group_name = azurerm_resource_group.default.name
  location            = azurerm_resource_group.default.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = module.bastion_label.tags
}

resource "azurerm_network_interface" "bastion" {
  name                 = module.bastion_label.id
  location             = azurerm_resource_group.default.location
  resource_group_name  = azurerm_resource_group.default.name
  enable_ip_forwarding = true

  dynamic "ip_configuration" {
    for_each = local.resolved_bastion_ip_configuration

    content {
      name                          = ip_configuration.value["name"]
      subnet_id                     = ip_configuration.value["subnet_id"]
      private_ip_address_allocation = ip_configuration.value["private_ip_address_allocation"]
      private_ip_address            = ip_configuration.value["private_ip_address"]
      public_ip_address_id          = ip_configuration.value["public_ip_address_id"]
      primary                       = ip_configuration.value["primary"]
    }
  }

  tags = module.bastion_label.tags
}

resource "azurerm_network_security_group" "bastion" {
  name                = module.bastion_label.id
  location            = azurerm_resource_group.default.location
  resource_group_name = azurerm_resource_group.default.name

  dynamic "security_rule" {
    for_each = local.bastion_security_group_rules
    content {
      name                       = security_rule.value.name
      priority                   = security_rule.value.priority
      direction                  = security_rule.value.direction
      access                     = security_rule.value.access
      protocol                   = security_rule.value.protocol
      source_port_range          = security_rule.value.source_port_range
      destination_port_range     = coalesce(security_rule.value.destination_port_range, "*")
      source_address_prefix      = coalesce(security_rule.value.source_address_prefix, "*")
      destination_address_prefix = coalesce(security_rule.value.destination_address_prefix, "*")
    }
  }

  tags = module.bastion_label.tags
}

resource "azurerm_network_interface_security_group_association" "bastion" {
  network_interface_id      = azurerm_network_interface.bastion.id
  network_security_group_id = azurerm_network_security_group.bastion.id
}

data "azurerm_platform_image" "bastion" {
  location  = azurerm_resource_group.default.location
  publisher = "canonical"
  offer     = "0001-com-ubuntu-server-focal"
  sku       = "20_04-lts-gen2"
  version   = null
}

resource "azurerm_linux_virtual_machine" "bastion" {
  name                = module.bastion_label.id
  location            = azurerm_resource_group.default.location
  resource_group_name = azurerm_resource_group.default.name
  size                = "Standard_D2s_v3"

  network_interface_ids = [
    azurerm_network_interface.bastion.id,
  ]

  admin_username = "ubuntu"

  source_image_reference {
    publisher = data.azurerm_platform_image.bastion.publisher
    offer     = data.azurerm_platform_image.bastion.offer
    sku       = data.azurerm_platform_image.bastion.sku
    version   = data.azurerm_platform_image.bastion.version
  }

  admin_ssh_key {
    username   = "ubuntu"
    public_key = tls_private_key.default.public_key_openssh
  }

  os_disk {
    caching              = "None"
    storage_account_type = "Standard_LRS"
  }

  tags = module.bastion_label.tags
}

##########################################################################################
# Private Server
##########################################################################################
module "private_label" {
  source     = "git::https://github.com/cloudposse/terraform-null-label.git?ref=0.25.0"
  attributes = ["private"]
  context    = module.label.context
}

locals {
  private_ingress_rules = [
    {
      priority                   = 100
      access                     = "Allow"
      protocol                   = "*"
      source_port_range          = "*"
      destination_port_range     = "22"
      source_address_prefix      = "0.0.0.0/0"
      destination_address_prefix = "0.0.0.0/0"
    }
  ]
  private_egress_rules = [
    {
      priority                   = 100
      access                     = "Allow"
      protocol                   = "*"
      source_port_range          = "*"
      destination_port_range     = "*"
      source_address_prefix      = "0.0.0.0/0"
      destination_address_prefix = "0.0.0.0/0"
    }
  ]

  private_default_ip_configuration = {
    name                          = module.private_label.id
    subnet_id                     = azurerm_subnet.server.id
    private_ip_address_allocation = "Static"
    private_ip_address            = local.private_private_ip
    public_ip_address_id          = null
    primary                       = true
  }

  resolved_private_ip_configuration = merge({}, { default = local.private_default_ip_configuration })

  resolved_private_ingress_security_group_rules = [for r in local.private_ingress_rules : {
    name                       = lower("inbound-${r.priority}-${r.access}-${r.protocol}-${r.source_port_range}-${r.destination_port_range}")
    description                = "${r.access} Inbound for ${r.protocol}"
    priority                   = r.priority
    direction                  = "Inbound"
    access                     = r.access
    protocol                   = r.protocol
    source_port_range          = r.source_port_range
    destination_port_range     = r.destination_port_range
    source_address_prefix      = r.source_address_prefix
    destination_address_prefix = r.destination_address_prefix
  }]

  resolved_private_egress_security_group_rules = [for r in local.private_egress_rules : {
    name                       = lower("outbound-${r.priority}-${r.access}-${r.protocol}-${r.source_port_range}-${r.destination_port_range}")
    description                = "${r.access} Outbound for ${r.protocol}"
    priority                   = r.priority
    direction                  = "Outbound"
    access                     = r.access
    protocol                   = r.protocol
    source_port_range          = r.source_port_range
    destination_port_range     = r.destination_port_range
    source_address_prefix      = r.source_address_prefix
    destination_address_prefix = r.destination_address_prefix
  }]

  private_security_group_rules = concat(local.resolved_private_ingress_security_group_rules, local.resolved_private_egress_security_group_rules)
}

resource "azurerm_network_interface" "private" {
  name                 = module.private_label.id
  location             = azurerm_resource_group.default.location
  resource_group_name  = azurerm_resource_group.default.name
  enable_ip_forwarding = true

  dynamic "ip_configuration" {
    for_each = local.resolved_private_ip_configuration

    content {
      name                          = ip_configuration.value["name"]
      subnet_id                     = ip_configuration.value["subnet_id"]
      private_ip_address_allocation = ip_configuration.value["private_ip_address_allocation"]
      private_ip_address            = ip_configuration.value["private_ip_address"]
      public_ip_address_id          = ip_configuration.value["public_ip_address_id"]
      primary                       = ip_configuration.value["primary"]
    }
  }

  tags = module.private_label.tags
}

resource "azurerm_network_security_group" "private" {
  name                = module.private_label.id
  location            = azurerm_resource_group.default.location
  resource_group_name = azurerm_resource_group.default.name

  dynamic "security_rule" {
    for_each = local.private_security_group_rules
    content {
      name                       = security_rule.value.name
      priority                   = security_rule.value.priority
      direction                  = security_rule.value.direction
      access                     = security_rule.value.access
      protocol                   = security_rule.value.protocol
      source_port_range          = security_rule.value.source_port_range
      destination_port_range     = coalesce(security_rule.value.destination_port_range, "*")
      source_address_prefix      = coalesce(security_rule.value.source_address_prefix, "*")
      destination_address_prefix = coalesce(security_rule.value.destination_address_prefix, "*")
    }
  }

  tags = module.private_label.tags
}

resource "azurerm_network_interface_security_group_association" "private" {
  network_interface_id      = azurerm_network_interface.private.id
  network_security_group_id = azurerm_network_security_group.private.id
}

data "azurerm_platform_image" "private" {
  location  = azurerm_resource_group.default.location
  publisher = "canonical"
  offer     = "0001-com-ubuntu-server-focal"
  sku       = "20_04-lts-gen2"
  version   = null
}

resource "azurerm_linux_virtual_machine" "private" {
  name                = module.private_label.id
  location            = azurerm_resource_group.default.location
  resource_group_name = azurerm_resource_group.default.name
  size                = "Standard_D2s_v3"

  network_interface_ids = [
    azurerm_network_interface.private.id,
  ]

  admin_username = "ubuntu"

  source_image_reference {
    publisher = data.azurerm_platform_image.private.publisher
    offer     = data.azurerm_platform_image.private.offer
    sku       = data.azurerm_platform_image.private.sku
    version   = data.azurerm_platform_image.private.version
  }

  admin_ssh_key {
    username   = "ubuntu"
    public_key = tls_private_key.default.public_key_openssh
  }

  os_disk {
    caching              = "None"
    storage_account_type = "Standard_LRS"
  }

  tags = module.private_label.tags
}

##########################################################################################
# OUTPUTS
##########################################################################################
locals {
  ssh_prefix        = "ssh -i ${local.private_key_filename}"
  ssh_proxy_command = "-o ProxyCommand=\"${local.ssh_prefix} -W %h:%p ubuntu@${azurerm_public_ip.bastion.ip_address}\""

  output_connect_cheatsheet = <<CONFIG
    bastion: ${local.ssh_prefix} ubuntu@${azurerm_public_ip.bastion.ip_address}
    private: ${local.ssh_prefix} ${local.ssh_proxy_command} ubuntu@${azurerm_network_interface.private.private_ip_address}
CONFIG
}

output "zdetails" {
  description = "Help details about the range"
  value       = <<EOF
Connection Cheatsheet
--------------------------------------------------------------------------------------
${local.output_connect_cheatsheet}
EOF
}
