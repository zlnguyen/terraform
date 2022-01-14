# Set Provider
provider "google" {
    project = "propane-galaxy-332307"  // Put your Project ID here
}

# Create VPC
resource "google_compute_network" "vpc" {
    name                      = "my-vpc"
    auto_create_subnetworks   = false  // Custom Subnets
}

# Create Subnet
resource "google_compute_subnetwork" "subnet" {
    name                        = "subnet-1"
    region                      = "us-central1"
    ip_cidr_range               = "10.0.1.0/24"
    
    # VPC
    network = google_compute_network.vpc.id    
}

# Create firewall rules
resource "google_compute_firewall" "allow-ssh" {
    name        = "fw-allow-ssh"
    network     = google_compute_network.vpc.id
    description = "Firewall rules to allow SSH"

    allow {
        protocol = "tcp"
        ports    = ["22"]
    }

    source_ranges   = ["0.0.0.0/0"]
}

# Create VMs
resource "google_compute_instance" "vm1" {
    name = "external-vm"
    zone = "us-central1-a"
    
    machine_type    = "n1-standard-1"

    boot_disk {
        initialize_params {
            image = "debian-cloud/debian-9"
        }
    }

    network_interface {
        network       = google_compute_network.vpc.id
        subnetwork    = google_compute_subnetwork.subnet.id

        access_config {} // assign external IP
    }    
}

resource "google_compute_instance" "vm2" {
    name = "internal-vm"
    zone = "us-central1-a"
    
    machine_type    = "n1-standard-1"

    boot_disk {
        initialize_params {
            image = "debian-cloud/debian-9"
        }
    }

    network_interface {
        network       = google_compute_network.vpc.id
        subnetwork    = google_compute_subnetwork.subnet.id
    }    
}
