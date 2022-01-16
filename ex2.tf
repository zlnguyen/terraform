locals {
    vpc     = "my-vpc"    
    subnets = {
        west = {
            region          = "us-west1"
            zone            = "us-west1-b"
            cidr            = "10.2.2.0/24"
            private_access  = true          //Google Private Access flag 

            # VM(s) and Group(s)
            vm              = ["first","second"]
            groups          = { 
                                my-group = {
                                    desc    = "My Un-Managed Group for West"
                                    vms     = ["first", "second"]
                                }
            }
        },
        east = {
            region          = "us-east1"        
            zone            = "us-east1-b"
            cidr            = "10.2.3.0/24"
            private_access  = false         //Google Private Access flag 
            vm              = ["third"]                        
        }
    }
    
    #Create VMs list
    temp_vm = flatten([
                        for sub in keys(local.subnets):[
                            for vm in local.subnets[sub].vm:{ subnet = sub, vm = vm }
                            ]
                        ])    
    vms = {for s in local.temp_vm: s.vm => {subnet = s.subnet }}

    #Define instance group
    temp_group = flatten([for sub in keys(local.subnets):[
                            for grp in keys(local.subnets[sub].groups): {                                
                                group   = grp,
                                zone    = local.subnets[sub].zone,
                                desc    = local.subnets[sub].groups[grp].desc,
                                vms     = local.subnets[sub].groups[grp].vms,
                            }
                         ] if can(local.subnets[sub].groups)])
    groups = {for grp in local.temp_group: grp.group => { zone = grp.zone, desc = grp.desc, vms = grp.vms} }
}

output "temp_vm"{
    value = local.temp_vm
}

output "vms"{
    value = local.vms
}

# Set Provider
provider "google" {
    project = "propane-galaxy-332307"
}

resource "google_compute_network" "vpc" {
    name                      = local.vpc
    auto_create_subnetworks   = false
}

resource "google_compute_subnetwork" "subnets" {
    for_each = local.subnets

    name                        = each.key
    region                      = each.value.region
    ip_cidr_range               = each.value.cidr
    private_ip_google_access    = each.value.private_access  

    #VPC
    network = google_compute_network.vpc.id    
}

# Create firewall rules
resource "google_compute_firewall" "allow-http" {
    name        = "fw-allow-http"
    network     = google_compute_network.vpc.id
    description = "Firewall rules to allow HTTP"

    allow {
        protocol = "tcp"
        ports    = ["80"]
    }

    target_tags     = ["http-server"]
    source_ranges   = ["0.0.0.0/0"]
}

resource "google_compute_firewall" "allow_iap" {
    name        = "fw-allow-iap-ssh"
    network     = google_compute_network.vpc.id
    description = "Firewall rules to allow IAP SSH"

    allow {
        protocol = "tcp"
        ports    = ["22"]
    }

    target_tags = ["network-allow-iap"]
    source_ranges = [ "35.235.240.0/20" ]
}

# Create NAT Gateway
resource "google_compute_router" "nat-routers" {
    for_each = local.subnets

    name    = "nat-router-${each.key}"
    region  = each.value.region
    
    network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat-gateways" {
    for_each =  google_compute_router.nat-routers
    
    name    = "nat-gw-${each.key}"
    region  = each.value.region
    router  = each.value.name
    
    nat_ip_allocate_option = "AUTO_ONLY"
    source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# Create VMs
resource "google_compute_instance" "vms" {
    # Make sure all the NAT Gateway(s) are already created
    depends_on = [
      google_compute_router_nat.nat-gateways
    ]

    for_each = local.vms

    name = each.key
    zone = local.subnets[each.value.subnet].zone
    
    machine_type    = "n1-standard-1"

    tags = [
        "http-server",
        "network-allow-iap"
    ]
    
    boot_disk {
        initialize_params {
            image = "debian-cloud/debian-9"
        }
    }

    network_interface {
        network       = google_compute_network.vpc.id
        subnetwork    = google_compute_subnetwork.subnets[each.value.subnet].id
    }

    service_account {
        scopes = [
            "cloud-platform"
        ]      
    }

    metadata = {
        "startup-script" = <<-EOT
        #! /bin/bash
        sudo su
        apt-get update
        apt-get install apache2 -y
        service apache2 restart
        cd /var/www/html
        gsutil cp gs://propane-myvpc-examples/html/index.html .
        sed -i 's/{num}/${each.key}/' index.html            
        EOT
    }    
}

# Put into un-managed instance group
resource "google_compute_instance_group" "vm-groups" {
    # Make sure all the VM(s) are already created    
    depends_on = [
      google_compute_instance.vms
    ]

    for_each = local.groups

    name        = each.key
    description = each.value.desc
    zone        = each.value.zone

    instances =  [
        for n in each.value.vms:
            google_compute_instance.vms[n].id
       ]
       
    named_port {
      name = "http"
      port = "80"
    }
}

# Create HTTP(S) Load Balancer
resource "google_compute_global_address" "ipv4_address" {
  name      = "ipv4-address"
}

resource "google_compute_health_check" "http" {
    name = "http-basic-check"
    
    http_health_check {
      port = 80
    }
}

# Create backend for each instance group
resource "google_compute_backend_service" "backends" {
    for_each =  google_compute_instance_group.vm-groups

    name            = "backend-${each.key}"
    protocol        = "HTTP" // this is optional, default is HTTP
    port_name       = "http"
    health_checks   = [
        google_compute_health_check.http.id   
    ]
    backend {
        group = each.value.id
    }    
}

resource "google_compute_url_map" "maps" {
    for_each =  google_compute_backend_service.backends
    
    name            = "http-lb${trimprefix(each.key,"backend")}"
    default_service = each.value.id
}

resource "google_compute_target_http_proxy" "proxies" {
    for_each =  google_compute_url_map.maps

    name        = "proxy-${each.key}"
    url_map     = each.value.id
  
}


resource "google_compute_global_forwarding_rule" "rule" {
    name        =  "http-content-rule"
    target      =  google_compute_target_http_proxy.proxies["my-group"].id
    port_range  = "80"
    ip_address  = google_compute_global_address.ipv4_address.id
  
}

/*
variable "project" {
  default = "propane-galaxy-332307"
}



variable "names" {
    type = list(string)
    default = [
        "west",
        "east"
    ]
}

variable "subnets" {
    type = list(string)
    default = [
        "subnet-west1",
        "subnet-east1"
    ]
}

variable "regions" {
    type = list(string) 
    default = [
        "us-west1",
        "us-east1",
    ]
}

variable "zones" {
    type = list(string) 
    default = [
        "us-west1-a",
        "us-east1-b",
    ]
}

variable "script_apache" {
    type = string
    default = <<EOF
        #! /bin/bash
        sudo apt-get-update
        sudo apt-get install apache2 -y
        sudo service apache2 restart
    EOF
}

provider "google" {
    project = var.project
}


/*
resource "google_compute_instance" "vm_test" {
    count           = 2
    name            = "terraform-instance${count.index}"
    machine_type    = "f1-micro"
    zone            = var.location

    boot_disk {
        initialize_params {
            image = "debian-cloud/debian-9"
        }
    }

    network_interface {
      network = "default"
    }

    provisioner "local-exec" {
        command = <<EOF
        echo "Instance ${count.index} is ${self.id}"
        EOF
    }
}


resource "google_compute_network" "vpc" {
    name                      = "myvpc"
    auto_create_subnetworks   = false
}

resource "google_compute_subnetwork" "west1" {
    name            = "${var.subnets[0]}"
    ip_cidr_range   = "10.2.2.0/24"
    region          = "${var.regions[0]}"
    network         = google_compute_network.vpc.id
}

resource "google_compute_subnetwork" "east1" {
    name            = "${var.subnets[1]}"
    ip_cidr_range   = "10.2.3.0/24"
    
    region          = "${var.regions[1]}"
    network         = google_compute_network.vpc.id
}

resource "google_compute_firewall" "rule_health_check" {
    name        = "fw-allow-health-check"
    network     = google_compute_network.vpc.id
    description = "Firewall rules to allow health check"

    allow {
      protocol = "tcp"
      ports = ["80"]
    }

    target_tags = [ "network-lb-tag" ]
    source_ranges = [
        "130.211.0.0/22",
        "35.191.0.0/16"
    ]
}

resource "google_compute_firewall" "rule_iap" {
    name        = "fw-allow-iap-ssh"
    network     = google_compute_network.vpc.id
    description = "Firewall rules to allow IAP SSH"

    allow {
        protocol = "tcp"
        ports    = ["22"]
    }

    target_tags = ["network-allow-iap"]
    source_ranges = [ "35.235.240.0/20" ]
}

resource "google_compute_firewall" "rule_http" {
    name        = "fw-allow-http"
    network     = google_compute_network.vpc.id
    description = "Firewall rules to allow HTTP"

    allow {
        protocol = "tcp"
        ports    = ["80"]
    }

    target_tags     = ["http-server"]
    source_ranges   = ["0.0.0.0/0"]
}

resource "google_compute_router" "router" {
    count   = 2
    name    = "myvpc-router-${local.names[count.index]}"
    region  = "${var.regions[count.index]}"
    network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
    count   = 2
    name    = google_compute_router.router[count.index].name
    region  = google_compute_router.router[count.index].region
    router  = google_compute_router.router[count.index].name
    
    nat_ip_allocate_option = "AUTO_ONLY"
    source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}


// TEST for LOAD BALANCER
/* THIS DOES NOT WORK DUE TO 403 ERROR
resource "google_compute_instance_from_machine_image" "www" {
    provider = google-beta
    count = 2
    name = "wwww${count.index}"
    zone = var.zones[count.index]
    tags = ["network-lb-tag"]    
    
    source_machine_image="https://www.googleapis.com/compute/v1/projects/debian-cloud/global/images/debian-9-stretch-v20211105"

    metadata = {
        "startup-script" = <<-EOT
            #! /bin/bash
            sudo su
            apt-get-update
            apt-get install apache2 -y
            service apache2 restart
            cd /var/www/html
            gsutil cp gs://propane-myvpc-examples/html/index.html .
            sed -i 's/{num}/${count.index+1}/' index.html
            echo '<
        EOT
    }       
}


resource "google_compute_global_address" "ipv4_address" {
  project   = var.project
  name      = "ipv4-address"
  
}

resource "google_compute_instance" "www" {
    depends_on = [
      google_compute_router_nat.nat
    ]
    count           = 3
    name            = "www${count.index}"
    zone            = count.index==0?var.zones[count.index]:var.zones[1]
    tags            = [
        "network-lb-tag",
        "http-server",
        "network-allow-iap"
    ]
    machine_type    = "n1-standard-1"

    boot_disk {
        initialize_params {
            image = "debian-cloud/debian-9"
        }
    }

    network_interface {
      network       = google_compute_network.vpc.id
      subnetwork    = count.index==0?var.subnets[count.index]:var.subnets[1]
    }

    metadata = {
        "startup-script" = <<-EOT
            #! /bin/bash
            sudo su
            apt-get update
            apt-get install apache2 -y
            service apache2 restart
            cd /var/www/html
            gsutil cp gs://propane-myvpc-examples/html/index.html .
            sed -i 's/{num}/${count.index+1}/' index.html            
        EOT
    }

    service_account {
        scopes = [
            "cloud-platform"
        ]      
    }

    provisioner "local-exec" {
        command = <<EOF
        echo "Instance ${count.index} is ${self.id}"
        EOF
    }
}

resource "google_compute_instance_group" "group" {
    depends_on = [
      google_compute_instance.www
    ]
    name        = "my-group"
    description = "My Test Unmanaged Instant Group"
    zone        = var.zones[1]

    instances = [
        for instance in google_compute_instance.www:
            instance.id
            if instance.zone == var.zones[1]
    ]

    named_port {
      name = "http"
      port = "80"
    }
}



resource "google_compute_health_check" "http" {
    name = "http-basic-check"
    
    http_health_check {
      port = 80
    }
}

resource "google_compute_backend_service" "backend" {
    name            = "web-backend-service"
    protocol        = "HTTP" // this is optional, default is HTTP
    port_name       = "http"
    health_checks   = [
        google_compute_health_check.http.id   
    ]
    backend {
        group = google_compute_instance_group.group.id
    }    
}

resource "google_compute_url_map" "map" {
    name            = "web-map-http"
    default_service = google_compute_backend_service.backend.id
}

resource "google_compute_target_http_proxy" "proxy" {
    name    = "http-lb-proxy"
    url_map = google_compute_url_map.map.id
  
}

resource "google_compute_global_forwarding_rule" "rule" {
    name        =  "http-content-rule"
    target      =  google_compute_target_http_proxy.proxy.id
    port_range  = "80"
    ip_address  = google_compute_global_address.ipv4_address.id
  
}*/

/*
output "test" {    
    value = [
        for instance in google_compute_instance.www:
            instance.name
            if instance.zone == var.zones[1]            
    ]
  
}*/

// create Global Network Balancer*/
