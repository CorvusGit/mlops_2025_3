# Выходные данные
output "proxy_public_ip" {
  value = yandex_compute_instance.proxy.network_interface[0].nat_ip_address
}

output "bucket_name" {
  value = yandex_storage_bucket.clean_bucket.bucket
}

# output "dataproc_master_fqdn" {
#   value = yandex_dataproc_cluster.dataproc_cluster.cluster_config[0].subcluster_spec[0].fqdn
# }