# IAM ресурсы
resource "yandex_iam_service_account" "sa" {
  name        = var.yc_service_account_name
  description = "Service account for Dataproc cluster and related services"
}

resource "yandex_resourcemanager_folder_iam_member" "sa_roles" {
  for_each = toset([
    "storage.admin",
    "dataproc.editor",
    "compute.admin",
    "dataproc.agent",
    "mdb.dataproc.agent",
    "vpc.user",
    "iam.serviceAccounts.user"
    #"storage.uploader",
    #"storage.viewer",
    #"storage.editor"
  ])

  folder_id = var.yc_folder_id
  role      = each.key
  member    = "serviceAccount:${yandex_iam_service_account.sa.id}"
}

resource "yandex_iam_service_account_static_access_key" "sa-static-key" {
  service_account_id = yandex_iam_service_account.sa.id
  description        = "Static access key for object storage"
}

# Network ресурсы
resource "yandex_vpc_network" "network" {
  name = var.yc_network_name
}

resource "yandex_vpc_subnet" "subnet" {
  name           = var.yc_subnet_name
  zone           = var.yc_zone
  network_id     = yandex_vpc_network.network.id
  v4_cidr_blocks = [var.yc_subnet_range]
  route_table_id = yandex_vpc_route_table.route_table.id
}

resource "yandex_vpc_gateway" "nat_gateway" {
  name = var.yc_nat_gateway_name
  shared_egress_gateway {}
}

resource "yandex_vpc_route_table" "route_table" {
  name       = var.yc_route_table_name
  network_id = yandex_vpc_network.network.id

  static_route {
    destination_prefix = "0.0.0.0/0"
    gateway_id         = yandex_vpc_gateway.nat_gateway.id
  }
}

resource "yandex_vpc_security_group" "security_group" {
  name        = var.yc_security_group_name
  description = "Security group for Dataproc cluster"
  network_id  = yandex_vpc_network.network.id

  ingress {
    protocol = "TCP"
    port = 22
    v4_cidr_blocks = ["${var.proxy_ip_address}/32"]
    description = "SSH allowed only from Proxy"
  }

  ingress {
    protocol = "ANY"
    predefined_target = "self_security_group"
    description = "Internal Dataproc traffic"
  }

  ingress {
    protocol = "TCP"
    port = 18080
    v4_cidr_blocks = ["${var.proxy_ip_address}/32"]
    description = "Web UI access only from Proxy"
  }

  ingress {
    protocol = "TCP"
    port = 8888
    v4_cidr_blocks = ["${var.proxy_ip_address}/32"]
    description = "Jupyter access only from Proxy"
  }

  egress {
    protocol = "ANY"
    v4_cidr_blocks = ["0.0.0.0/0"]
    description = "Full outbound access"
  }

}

# Storage ресурсы
# устраняем ошибку apply
resource "time_sleep" "wait_for_s3_key" {
  depends_on = [
    yandex_iam_service_account_static_access_key.sa-static-key
  ]
  create_duration = "30s"
}

resource "yandex_storage_bucket" "clean_bucket" {
  depends_on = [time_sleep.wait_for_s3_key]

  bucket        = "${var.yc_bucket_name}-${var.yc_folder_id}"
  access_key    = yandex_iam_service_account_static_access_key.sa-static-key.access_key
  secret_key    = yandex_iam_service_account_static_access_key.sa-static-key.secret_key
  force_destroy = true
}

#Загружаем скрипт очиcтки на новый бакет
resource "yandex_storage_object" "spark_job_script" {
  bucket = yandex_storage_bucket.clean_bucket.bucket
  key    = "scpts/clean_data.py"
  source = "${path.module}/scripts/clean_data.py"
  content_type = "text/x-python"
}

# key for mster node
resource "tls_private_key" "cluster_key" {
  algorithm = "ED25519"
}

# Dataproc ресурсы
resource "yandex_dataproc_cluster" "dataproc_cluster" {
  depends_on  = [yandex_resourcemanager_folder_iam_member.sa_roles]
  bucket      = yandex_storage_bucket.clean_bucket.bucket
  description = "Dataproc Cluster created by Terraform for OTUS project"
  name        = var.yc_dataproc_cluster_name
  labels = {
    created_by = "terraform"
  }
  service_account_id = yandex_iam_service_account.sa.id
  zone_id            = var.yc_zone
  security_group_ids = [yandex_vpc_security_group.security_group.id]

  cluster_config {
    version_id = var.yc_dataproc_version

    hadoop {
      services = ["HDFS", "YARN", "SPARK"] # "HIVE", "TEZ"
      properties = {
        "yarn:yarn.resourcemanager.am.max-attempts" = 5
      }
      ssh_public_keys =[
        tls_private_key.cluster_key.public_key_openssh,
      "${file(var.public_key_path_mn)}"
      ]
    }

    subcluster_spec {
      name = "master"
      role = "MASTERNODE"
      resources {
        resource_preset_id = var.dataproc_master_resources.resource_preset_id
        disk_type_id       = "network-ssd"
        disk_size          = var.dataproc_master_resources.disk_size
      }
      subnet_id        = yandex_vpc_subnet.subnet.id
      hosts_count      = 1
      #assign_public_ip = true
    }

    subcluster_spec {
      name = "data"
      role = "DATANODE"
      resources {
        resource_preset_id = var.dataproc_data_resources.resource_preset_id
        disk_type_id       = "network-ssd"
        disk_size          = var.dataproc_data_resources.disk_size
      }
      subnet_id   = yandex_vpc_subnet.subnet.id
      hosts_count = 3
    }

    # subcluster_spec {
    #   name = "compute"
    #   role = "COMPUTENODE"
    #   resources {
    #     resource_preset_id = var.dataproc_compute_resources.resource_preset_id
    #     disk_type_id       = "network-ssd"
    #     disk_size          = var.dataproc_compute_resources.disk_size
    #   }
    #   subnet_id   = yandex_vpc_subnet.subnet.id
    #   hosts_count = 1
    # }
  }
}

# Compute ресурсы
resource "yandex_compute_disk" "boot_disk" {
  name     = "boot-disk"
  zone     = var.yc_zone
  image_id = var.yc_image_id
  size     = 30
}

locals {
  user_data  = file("${path.root}/scripts/user_data.sh")
  upload_data_to_hdfs  = file("${path.root}/scripts/upload_data_to_hdfs.sh")
}

resource "yandex_compute_instance" "proxy" {
  name                      = var.yc_instance_name
  allow_stopping_for_update = true
  platform_id               = "standard-v3"
  zone                      = var.yc_zone
  service_account_id        = yandex_iam_service_account.sa.id

  metadata = {
    //ssh-keys = "ubuntu:${file(var.ssh_public_key)}"
    user-data = templatefile("${path.root}/templates/cloud-init.yaml", {
      #user_name = var.proxy_user_name
      user_data_sh = indent(6, local.user_data)
      upload_data_to_hdfs_sh   = indent(6, local.upload_data_to_hdfs)
      public_key = "${file(var.public_key_path)}"
      cluster_key =  base64encode(tls_private_key.cluster_key.private_key_openssh)
      token = var.yc_token
      cloud_id = var.yc_cloud_id
      folder_id = var.yc_folder_id
      access_key = "${yandex_iam_service_account_static_access_key.sa-static-key.access_key}"
      secret_key = "${yandex_iam_service_account_static_access_key.sa-static-key.secret_key}"
      source_bucket = "${var.yc_source_bucket_name}-${var.yc_folder_id}"
    })
  }

  scheduling_policy {
    preemptible = true
  }

  resources {
    cores  = 2
    memory = 16
  }

  boot_disk {
    disk_id = yandex_compute_disk.boot_disk.id
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.subnet.id
    nat       = true
    ip_address = var.proxy_ip_address
  }

  metadata_options {
    gce_http_endpoint = 1
    gce_http_token    = 1
  }

  # connection {
  #   type        = "ssh"
  #   user        = "ubuntu"
  #   private_key = file(var.private_key_path)
  #   host        = self.network_interface[0].nat_ip_address
  # }
  
  depends_on = [yandex_dataproc_cluster.dataproc_cluster]
}


#preserve_hostname: false